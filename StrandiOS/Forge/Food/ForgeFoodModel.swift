#if os(iOS)
import Foundation
import Observation
import StrandCore
import StrandAnalytics
import WhoopStore

/// The Food page's state: one day of the shared food log (`FoodLog`), the calorie goal (`FoodTargets`) and the
/// seven-day nutrient report (`FoodNutrientReport`), plus the actions the page and its sheets run. Health writing
/// goes through `FoodHealthSync`, so every add or removal reaches Apple Health the same way.
@MainActor
@Observable
final class ForgeFoodModel {
    var day: String = Repository.localDayKey(.now)
    private(set) var summary: FoodLog.DaySummary?
    /// The goal without a diet plan: the energy plan's, or the wearer's own fixed one.
    private(set) var baseCalories: FoodTargets.Calories?
    /// The shown day's calorie goal: the diet plan's for that day when there is one (a fasting day has its own),
    /// otherwise the base goal. One resolver for the plate, the figures and the week strip.
    var calories: FoodTargets.Calories? { calories(for: day) }

    /// Any day's calorie goal: the plan's for that day (its fasting figure, its active-day extra), or the base goal.
    func calories(for day: String) -> FoodTargets.Calories? {
        if let resolved = planDay(day) { return resolved.calories }
        return baseCalories
    }

    /// One day of the plan from the shared `DietDayResolver`, the resolver the Android core calls too: phase,
    /// training-day shift, active-day extra and the burn the plan starts from. Nil without a plan or a person.
    func planDay(_ day: String) -> DietDayResolver.Day? {
        _ = burnRevision
        guard let plan, let person, let strap = strapBurnKcal else { return nil }
        let inputs = DietDayResolver.Inputs(plan: plan, person: person, strapBurnKcal: strap, kcalPerKg: kcalPerKg,
                                            burnedByDay: burnedByDay, completeDays: trackerComplete,
                                            intakeByDay: trackerIntake, weighIns: recentWeights, training: training,
                                            today: Repository.localDayKey(.now))
        return DietDayResolver.resolve(inputs, day: day)
    }
    @ObservationIgnored private var trackerComplete: Set<String> = []
    @ObservationIgnored private var trackerIntake: [String: Double] = [:]
    private(set) var nutrients: FoodNutrientReport.Report?
    /// The shown day alone, for its nutrition facts and the pinned nutrients.
    private(set) var dayNutrients: FoodNutrientReport.Report?
    /// Gram goals for protein, carbohydrate and fat, from the calorie goal and the wearer's split.
    var macroGoals: FoodTargets.Macros? { macroGoals(for: day) }

    /// Any day's macro goals, from the same resolver as `calories(for:)`.
    func macroGoals(for day: String) -> FoodTargets.Macros? {
        if let resolved = planDay(day) { return resolved.macros }
        guard let kcal = calories(for: day)?.kcal else { return nil }
        let d = UserDefaults.standard, split = FoodTargets.defaultSplit
        func share(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        return FoodTargets.macros(kcal: kcal, protein: share(FoodTargets.Keys.proteinPercent, split.protein),
                                  carbs: share(FoodTargets.Keys.carbsPercent, split.carbs),
                                  fat: share(FoodTargets.Keys.fatPercent, split.fat))
    }
    var pinned: [FoodNutrient] { FoodTargets.pinned(from: UserDefaults.standard.string(forKey: FoodTargets.Keys.pinned)) }
    private(set) var catalogFailed = false
    private(set) var loaded = false
    /// The plan's intake for the day when it comes from somewhere other than this log.
    private(set) var otherIntake: (kcal: Double, source: NutritionDay.Source)?

    @ObservationIgnored private var catalogReady = false
    @ObservationIgnored private var references: [FoodNutrient: FoodReference.Value] = [:]
    @ObservationIgnored private let energy = EnergyPlanModel()

    var isToday: Bool { day == Repository.localDayKey(.now) }
    /// What each recent day burned as measured by the strap and Health, today until now.
    @ObservationIgnored private var burnedByDay: [String: Double] = [:]
    private(set) var burnRevision = 0
    /// The shown day's measured burn; nil before the energy plan has loaded or beyond its window.
    var burned: Double? { _ = burnRevision; return burnedByDay[day] }
    var eatenKcal: Double { summary?.totals[.energyKcal] ?? 0 }
    /// Stored groups of the shown day's foods whose id does not name one, for the meal pictures.
    private(set) var groupsById: [String: String] = [:]
    /// A meal eaten on several of the last days, offered again at its time of day (today only).
    private(set) var habit: FoodRepeat.Suggestion?
    /// Seven days for the week strip, oldest first, each with its totals (empty for a day without a log).
    private(set) var week: [WeekDay] = []
    /// The week's nutrition score; nil while the Lab switch is off or fewer than five days carry a log.
    private(set) var score: FoodScore.Result?
    /// Logged days in the score's window, for "after five logged days" while there is no score yet.
    private(set) var scoreLoggedDays = 0
    var scoreEnabled: Bool { UserDefaults.standard.bool(forKey: FoodScore.enabledKey) }

    struct WeekDay: Equatable, Identifiable {
        let day: String
        let totals: NutrientAmounts
        var id: String { day }
        var logged: Bool { !totals.isEmpty }
    }

    /// The evening's observations for the shown day, read against the plate's and the card's goals. Empty
    /// before 18:00 on today.
    func sentence(now: Date = .now) -> [FoodDaySentence.Point] {
        if isToday, Calendar.current.component(.hour, from: now) < FoodDaySentence.fromHour { return [] }
        guard let totals = summary?.totals, !(summary?.entries.isEmpty ?? true) else { return [] }
        return FoodDaySentence.points(totals: totals, proteinGoalG: macroGoals?.proteinG, references: references)
    }

    // MARK: Diet plan (decision 2026-11-09)

    /// The wearer's diet plan, nil until they made one in the planner.
    private(set) var plan: DietPlan? = DietPlan.decode(UserDefaults.standard.string(forKey: DietPlan.storageKey))
    private(set) var planResult: DietTargets.Result?
    /// This week's look at the plan: a change Forge made (simple mode, with undo) or proposes (advanced mode).
    private(set) var planWeek: DietAdjust.Outcome?
    private(set) var planWeekApplied = false
    @ObservationIgnored private(set) var person: DietPerson?
    @ObservationIgnored private(set) var planBurnKcal: Double?
    /// The strap's usual burn for a whole day, whatever the plan starts from; active days are measured against it.
    @ObservationIgnored private var strapBurnKcal: Double?
    /// The real burn from completely logged days and the weight trend, or what it still needs (owner, 2026-11-10).
    private(set) var expenditure: DietExpenditure.Outcome?
    /// The shown day is marked as completely logged.
    private(set) var dayComplete = false
    /// The way to the goal weight, or holding, from the weight trend.
    private(set) var progress: DietProgress.Progress?

    /// The extra calories an active day brings for `day`; zero when the plan has it off.
    func activeBonusKcal(for day: String) -> Double { planDay(day)?.activeBonusKcal ?? 0 }
    @ObservationIgnored private(set) var kcalPerKg: Double?

    /// Today's weight for the planner's starting point.
    var currentWeightKg: Double? { person?.weightKg }

    /// The program's phase of `day`: a break week, the step after the goal, holding, or the plan itself.
    func phase(for day: String) -> DietProgram.Phase {
        guard let plan else { return .main }
        return DietProgram.phase(on: day, plan: plan, goalReachedDay: goalReachedDay)
    }
    @ObservationIgnored private var goalReachedDay: String?
    @ObservationIgnored private var resultByPhase: [DietProgram.Phase: DietTargets.Result] = [:]

    /// The plan's numbers for `day`: the main result, or the same plan resolved for the day's phase.
    func result(for day: String) -> DietTargets.Result? {
        let p = phase(for: day)
        if p == .main { return planResult }
        if let cached = resultByPhase[p] { return cached }
        guard let plan, let person, let burn = planBurnKcal else { return planResult }
        let r = DietTargets.resolve(plan, person: person, burnKcal: burn, kcalPerKg: kcalPerKg, phase: p)
        resultByPhase[p] = r
        return r
    }

    /// A plan's calories on `day` with that day's phase and training share, without the active-day extra: the same
    /// basis for the plan in force and for a proposed one, so a before and after compare like with like.
    func plannedKcal(on day: String, plan candidate: DietPlan) -> Double? {
        guard let person, let burn = planBurnKcal else { return nil }
        let p = DietProgram.phase(on: day, plan: candidate, goalReachedDay: goalReachedDay)
        let r = DietTargets.resolve(candidate, person: person, burnKcal: burn, kcalPerKg: kcalPerKg, phase: p)
        return DietTargets.kcal(on: day, plan: candidate, result: r, training: training)
    }

    private func resolvePlan() {
        resultByPhase = [:]
        goalReachedDay = plan.flatMap { p in
            DietProgram.goalReachedDay(plan: p, goalWeightKg: person.flatMap { DietTargets.plannedGoalWeight(p, person: $0) },
                                       weighIns: recentWeights)
        }
        defer { updateProgress() }
        guard let plan, let person, let burn = planBurnKcal else { planResult = nil; return }
        planResult = DietTargets.resolve(plan, person: person, burnKcal: burn, kcalPerKg: kcalPerKg)
    }

    /// The forecast for the plan as it stands.
    func forecast() -> DietForecast.Forecast? {
        guard let plan, let planResult else { return nil }
        return DietForecast.project(startKg: person?.weightKg ?? plan.startWeightKg, goalKg: planResult.goalWeightKg,
                                    intakeKcal: planResult.averageKcal, burnKcal: planResult.burnKcal,
                                    kcalPerKg: kcalPerKg ?? DietTargets.defaultKcalPerKg,
                                    dietBreakEveryWeeks: DietProgram.dietBreakEveryWeeks(plan))
    }

    /// Saves a plan from the planner or the plan page and recomputes every goal from it.
    func savePlan(_ next: DietPlan?) {
        if let next, let raw = next.encoded() {
            UserDefaults.standard.set(raw, forKey: DietPlan.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: DietPlan.storageKey)
        }
        plan = next
        planWeek = nil
        resolvePlan()
    }

    /// Once a week: compares the planned pace with the weight trend. In the simple mode with Forge steering the
    /// change is made at once (with undo); otherwise it waits for the wearer.
    private func weeklyCheck(repo: Repository, store: WhoopStore) async {
        guard var current = plan, let planResult else { return }
        let today = Repository.localDayKey(.now)
        guard current.lastAdjustedDay != today else { return }
        let weights = await repo.weightDailyValues(days: 21).map { (day: $0.day, kg: $0.value) }
        guard let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: .now) else { return }
        let logged = Set(((try? await store.foodLogEntries(from: Repository.localDayKey(weekStart), to: today)) ?? []).map(\.day)).count
        let outcome = DietAdjust.weekly(plan: current, result: planResult, weighIns: weights, loggedDays: logged,
                                        today: today, kcalPerKg: kcalPerKg ?? DietTargets.defaultKcalPerKg, phase: phase(for: today))
        planWeek = outcome
        planWeekApplied = false
        guard outcome.hold == nil else { return }
        if current.mode == .simple && current.steering == .coached {
            current.adjustmentKcal += outcome.changeKcal
            current.lastAdjustedDay = today
            savePlan(current)
            planWeek = outcome
            planWeekApplied = true
        }
    }

    /// Advanced mode: takes Forge's proposed change.
    func acceptPlanChange() {
        guard var current = plan, let change = planWeek?.changeKcal else { return }
        current.adjustmentKcal += change
        current.lastAdjustedDay = Repository.localDayKey(.now)
        let outcome = planWeek
        savePlan(current)
        planWeek = outcome
        planWeekApplied = true
    }

    /// Keeps the calories as they are for this week (advanced), or undoes the change Forge just made (simple).
    func declinePlanChange() {
        guard var current = plan, let outcome = planWeek else { return }
        if planWeekApplied { current.adjustmentKcal -= outcome.changeKcal }
        current.lastAdjustedDay = Repository.localDayKey(.now)
        savePlan(current)
        planWeek = nil
    }

    /// The evening's word about the plan: a group it keeps rare that filled a quarter of the day.
    func offPlanSentence(now: Date = .now) -> String? {
        if isToday, Calendar.current.component(.hour, from: now) < FoodDaySentence.fromHour { return nil }
        guard let plan, let entries = summary?.entries,
              let motif = FoodDaySentence.offPlan(entries: entries, groups: groupsById, form: plan.form, addon: plan.addon) else { return nil }
        // Mid-sentence names go lower case, except in German, which capitalises its nouns.
        let locale = AppLanguage.activeLocale
        let inSentence: (String) -> String = { locale.language.languageCode?.identifier == "de" ? $0 : $0.lowercased(with: locale) }
        return String(localized: "Quite a lot of \(inSentence(FoodText.motif(motif))) for \(inSentence(DietText.form(plan.form))).")
    }

    /// Bumped on every successful add, so the page can answer it with a tap of haptics.
    private(set) var savedRevision = 0

    func load(repo: Repository, profile: UserProfile) async {
        guard let store = await repo.storeHandle() else { return }
        // The day first, so the page fills before the catalogue and the energy plan have loaded.
        summary = await FoodLog.day(store: store, day)
        if !catalogReady {
            do { try await FoodCatalog.shared.prepareBundled(); catalogReady = true } catch { catalogFailed = true }
        }
        await energy.load(repo: repo, profile: profile)
        let planned = FoodTargets.calories(measuredMeanKcal: energy.burn.measuredMeanKcal,
                                           allDaysMeanKcal: energy.burn.allDaysMeanKcal,
                                           formulaTdeeKcal: energy.formulaTdee(profile: profile),
                                           dailyDeltaKcal: energy.targetDailyKcal)
        baseCalories = FoodTargets.calories(fixedKcal: UserDefaults.standard.double(forKey: FoodTargets.Keys.calories), plan: planned)
        person = DietPerson(weightKg: profile.weightKg, heightCm: profile.heightCm > 0 ? profile.heightCm : nil,
                            age: profile.age > 0 ? Int(profile.age) : nil,
                            male: profile.sex.lowercased() == "male" ? true : profile.sex.lowercased() == "female" ? false : nil)
        strapBurnKcal = energy.burn.measuredMeanKcal ?? energy.burn.allDaysMeanKcal ?? energy.formulaTdee(profile: profile)
        kcalPerKg = energy.observedKcalPerKg
        burnedByDay = energy.burnedByDay
        await loadBody(repo: repo)
        await loadTracker(repo: repo, store: store)
        #if DEBUG
        seedDemoPlanIfRequested()
        #endif
        resolvePlan()
        await weeklyCheck(repo: repo, store: store)
        await loadAdvice(store: store)
        burnRevision += 1
        male = profile.sex.lowercased() == "male" ? true : profile.sex.lowercased() == "female" ? false : nil
        references = FoodReference.values(profileSex: profile.sex, age: Int(profile.age), weightKg: profile.weightKg,
                                          heightCm: profile.heightCm, energyKcal: calories?.kcal)
        await reload(store: store)
        loaded = true
        // Photos of carts that were never saved, once they are a day old.
        if let photos = FoodPhotoStore.appDefault, let kept = try? await store.allFoodPhotoIds() {
            Task.detached(priority: .utility) { photos.sweep(keeping: kept) }
        }
    }

    /// The real burn and the way to the goal: completely logged days, intake and weigh-ins of the last weeks.
    /// The plan starts from the real burn when the wearer chose it and it is known, otherwise from the strap.
    private func loadTracker(repo: Repository, store: WhoopStore) async {
        let today = Repository.localDayKey(.now)
        let from = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(DietExpenditure.windowDays - 1),
                                                                to: .now) ?? .now)
        let complete = (try? await store.foodCompleteDays(from: from, to: today)) ?? []
        // What the energy plan counts per day: a typed day value or an import wins over the food log there, so it
        // does here too (one intake per day, wherever it is read).
        let intake = (await NutritionReads.nutritionByDay(store: store, from: from, to: today))
            .compactMapValues { $0.calories }
        let weights = await repo.weightDailyValues(days: 120).map { (day: $0.day, kg: $0.value) }
        trackerComplete = complete
        trackerIntake = intake
        expenditure = DietExpenditure.estimate(intakeByDay: intake, completeDays: complete, weighIns: weights,
                                               strapByDay: burnedByDay, today: today,
                                               kcalPerKg: kcalPerKg ?? DietTargets.defaultKcalPerKg)
        if plan?.burnSource == .scale, case .estimate(let e) = expenditure { planBurnKcal = e.burnKcal }
        else { planBurnKcal = strapBurnKcal }
        recentWeights = weights
    }

    @ObservationIgnored private var recentWeights: [(day: String, kg: Double)] = []
    @ObservationIgnored private var bodyFatReadings: [(day: String, value: Double)] = []
    @ObservationIgnored private var waistReadings: [(day: String, value: Double)] = []
    @ObservationIgnored private var strengthChangePercent: Double?
    /// Days with logged strength training over the last months: training days for the plan's shift.
    private(set) var strengthDays: Set<String> = []
    /// Training days: the training planner's sessions and logged strength training.
    var training: DietTrainingDays { DietTrainingDays(planned: plannedTrainingDays, logged: strengthDays) }
    /// Days the training planner has a strength or hard session on, from four weeks back to two ahead.
    private(set) var plannedTrainingDays: Set<String> = []

    /// Whether `day` is a training day for the plan.
    func isTrainingDay(_ day: String) -> Bool {
        guard let plan else { return false }
        return DietTargets.isTrainingDay(day, plan: plan, training: training)
    }

    /// The training planner's training days in the coming week, for the planner's training step.
    var plannedTrainingDaysThisWeek: [String] {
        let today = Repository.localDayKey(.now)
        let until = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: 6, to: .now) ?? .now)
        return plannedTrainingDays.filter { $0 >= today && $0 <= until }.sorted()
    }

    /// Weekdays the wearer trained strength on at least twice in the last four weeks, at most the five most frequent
    /// (a shift needs rest days to take from), for the planner's proposal.
    var usualTrainingWeekdays: [Int] { DietTrainingDays.usualWeekdays(logged: strengthDays) }

    // MARK: Suggestions (owner, 2026-11-10)

    /// This week's suggestions for the plan, at most three.
    private(set) var advice: [DietAdvice.Suggestion] = []
    /// Mean protein on the logged days of the last seven, the figure the protein suggestion is about.
    private(set) var proteinMean7: Double?
    @ObservationIgnored private var strengthChange4Weeks: Double?
    private static let adviceDismissedKey = "food.advice.dismissed"

    /// Monday of this week, so a dismissed suggestion comes back the week after.
    private static var adviceWeek: String {
        var c = Calendar.current; c.firstWeekday = 2
        return Repository.localDayKey(c.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now)
    }

    private func loadAdvice(store: WhoopStore) async {
        guard let plan, let planResult else { advice = []; return }
        let cal = Calendar.current
        func key(_ back: Int) -> String { Repository.localDayKey(cal.date(byAdding: .day, value: -back, to: .now) ?? .now) }
        let today = key(0)
        let days21 = await FoodLog.totals(store: store, from: key(20), to: today).filter { !$0.totals.isEmpty }
        let last7 = days21.filter { $0.day >= key(6) }
        let proteins = last7.compactMap { $0.totals[.proteinG] }
        let weights7 = recentWeights.filter { $0.day >= key(6) }.count
        let trend = DietAdjust.slopePerWeek(recentWeights.filter { $0.day >= key(20) })
        let age = WeightSeries.date(forDay: plan.startDay).flatMap { cal.dateComponents([.day], from: $0, to: .now).day } ?? 0
        let p = phase(for: today)
        proteinMean7 = proteins.isEmpty ? nil : proteins.reduce(0, +) / Double(proteins.count)
        let inputs = DietAdvice.Inputs(goal: planResult.goal, proteinMeanG: proteinMean7,
                                       proteinGoalG: planResult.proteinG, weighInsLast7: weights7, loggedDaysLast7: last7.count,
                                       strengthChange4WeeksPercent: strengthChange4Weeks, trend3WeeksKgPerWeek: trend,
                                       loggedDaysLast21: days21.count, inBreakOrHolding: p != .main, planAgeDays: age)
        let dismissed = Set((UserDefaults.standard.stringArray(forKey: Self.adviceDismissedKey) ?? [])
            .filter { $0.hasPrefix(Self.adviceWeek + ":") }
            .compactMap { DietAdvice.Kind(rawValue: String($0.dropFirst(Self.adviceWeek.count + 1))) })
        advice = DietAdvice.suggestions(inputs, dismissed: dismissed)
    }

    /// Takes a suggestion that changes the plan; one that opens a page is handled by the page.
    func takeAdvice(_ s: DietAdvice.Suggestion) {
        guard let plan, let next = DietAdvice.applying(s, to: plan, today: Repository.localDayKey(.now)) else { return }
        savePlan(next)
        dismissAdvice(s)
    }

    /// Hides a suggestion for the rest of this week.
    func dismissAdvice(_ s: DietAdvice.Suggestion) {
        var list = (UserDefaults.standard.stringArray(forKey: Self.adviceDismissedKey) ?? []).filter { $0.hasPrefix(Self.adviceWeek + ":") }
        list.append(Self.adviceWeek + ":" + s.kind.rawValue)
        UserDefaults.standard.set(list, forKey: Self.adviceDismissedKey)
        advice.removeAll { $0.kind == s.kind }
    }

    /// Body fat, waist and strength for recomposition, read once per load.
    private func loadBody(repo: Repository) async {
        let metrics = await repo.bodyMetrics(days: 365)
        bodyFatReadings = metrics.series("body_fat").map { ($0.day, $0.value) }
        waistReadings = metrics.series("waist").map { ($0.day, $0.value) }
        person?.bodyFatPercent = metrics.latest("body_fat")?.value
        plannedTrainingDays = DietTrainingPlan.days(from: CoachPlanStore.shared.proposals)
        let history = await repo.resolvedStrengthHistory(days: 365)
        let offset = TimeZone.current.secondsFromGMT()
        strengthDays = Set(TrainingLoadLanes.strengthByDay(history.workouts, tzOffsetSeconds: offset).filter { $0.value > 0 }.keys)
        strengthChangePercent = plan.flatMap { p in
            StrengthSession.mainLiftChangePercent(workouts: history.workouts, templates: history.templates, since: p.startDay,
                                                  tzOffsetSeconds: offset)
        }
        strengthChange4Weeks = StrengthSession.mainLiftChangePercent(
            workouts: history.workouts, templates: history.templates,
            since: Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -28, to: .now) ?? .now), tzOffsetSeconds: offset)
    }

    #if DEBUG
    /// `--demo-seed`: a plan that started four weeks ago at that day's weight, ten kilograms to lose, active days
    /// on, so the way to the goal, the real burn and the active-day extra show on the demo store.
    private func seedDemoPlanIfRequested() {
        let args = CommandLine.arguments
        let wantsRecomp = args.contains("--demo-recomp") && plan?.goal != .recomp
        guard args.contains("--demo-seed"), plan == nil || wantsRecomp,
              let cutoff = Calendar.current.date(byAdding: .day, value: -28, to: .now) else { return }
        let window = recentWeights.filter { (WeightSeries.date(forDay: $0.day) ?? .distantPast) >= cutoff }
        guard let first = window.first ?? recentWeights.first else { return }
        if wantsRecomp {
            // `--demo-recomp`: recomposition from four weeks ago, training Monday, Wednesday and Friday.
            var recomp = DietPlan(goal: .recomp, form: .highProtein, strength: true, startDay: first.day, startWeightKg: first.kg)
            recomp.trainingWeekdays = [2, 4, 6]
            recomp.experience = .returning
            savePlan(recomp)
            return
        }
        savePlan(DietPlan(goal: .lose, pacePercent: 0.5, form: .balanced, goalWeightKg: (first.kg - 10).rounded(),
                          startDay: first.day, startWeightKg: first.kg, activeDays: true))
    }
    #endif

    /// The way to the goal from the plan as resolved (its goal weight may have been raised to a healthy one).
    private func updateProgress() {
        progress = plan.flatMap {
            DietProgress.resolve(plan: $0, goalWeightKg: planResult?.goalWeightKg, weighIns: recentWeights,
                                 bodyFat: bodyFatReadings, waist: waistReadings, strengthChangePercent: strengthChangePercent)
        }
    }

    /// Marks the shown day as completely logged, or takes it back; only marked days count toward the real burn.
    func setDayComplete(_ complete: Bool, repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        try? await store.setFoodDayComplete(day, complete)
        dayComplete = complete
        await loadTracker(repo: repo, store: store)
        resolvePlan()
    }

    /// Switches what the plan's usual burn comes from. The weekly adjustments so far start again at zero, since
    /// they corrected a gap the new figure already contains.
    func setBurnSource(_ source: DietPlan.BurnSource, repo: Repository) async {
        guard var current = plan, current.burnSource != source else { return }
        current.burnSource = source
        current.adjustmentKcal = 0
        savePlan(current)
        guard let store = await repo.storeHandle() else { return }
        await loadTracker(repo: repo, store: store)
        resolvePlan()
    }

    /// Turns active days on or off.
    func setActiveDays(_ on: Bool) {
        guard var current = plan else { return }
        current.activeDays = on
        savePlan(current)
    }

    /// After the goal settings changed.
    func reloadGoals(repo: Repository, profile: UserProfile) async { await load(repo: repo, profile: profile) }

    func reload(repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        await reload(store: store)
    }

    private func reload(store: WhoopStore) async {
        summary = await FoodLog.day(store: store, day)
        dayComplete = ((try? await store.foodCompleteDays(from: day, to: day)) ?? []).contains(day)
        await resolveGroups(store: store)
        await findHabit(store: store)
        await loadWeek(store: store)
        otherIntake = await FoodLog.otherIntake(store: store, day)
        if !references.isEmpty {
            nutrients = await FoodNutrientReport.report(store: store, to: day, references: references)
            dayNutrients = FoodNutrientReport.report(entries: summary?.entries ?? [], from: day, to: day, references: references)
        }
    }

    /// Looks up the group of foods whose id does not carry it (products, own foods), once per food.
    private func resolveGroups(store: WhoopStore) async {
        let ids = Set((summary?.entries ?? []).compactMap(\.foodId))
            .filter { FoodGroupMotif.forFoodId($0) == nil && groupsById[$0] == nil }
        for id in ids {
            if let group = await FoodLibrary.item(store: store, id: id)?.group { groupsById[id] = group }
        }
    }

    /// The week strip ends today while the shown day is within its seven days, else on the shown day, so tapping
    /// a day of the strip does not move the strip.
    private func loadWeek(store: WhoopStore) async {
        let days = FoodLog.weekDays(shown: day, today: Repository.localDayKey(.now))
        guard let first = days.first, let last = days.last else { return }
        let entries = (try? await store.foodLogEntries(from: first, to: last)) ?? []
        let byDay = Dictionary(grouping: entries, by: \.day)
        week = days.map { WeekDay(day: $0, totals: .sum((byDay[$0] ?? []).map { NutrientAmounts(stored: $0.totals) })) }
        scoreLoggedDays = byDay.count
        guard scoreEnabled else { score = nil; return }
        var facts: [String: FoodScore.FoodFacts] = [:]
        for id in Set(entries.compactMap(\.foodId)) where !id.hasPrefix("bls:") {
            if let item = await FoodLibrary.item(store: store, id: id) { facts[id] = .init(group: item.group, nova: item.nova) }
        }
        score = FoodScore.week(entries: entries, lastDay: last, facts: facts, male: male)
    }

    /// From the profile; nil when it names neither, which takes the lower whole-grain and alcohol limits.
    private(set) var male: Bool?

    private func findHabit(store: WhoopStore) async {
        guard isToday, let date = WeightSeries.date(forDay: day),
              let start = Calendar.current.date(byAdding: .day, value: -FoodRepeat.window, to: date),
              let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: date) else { habit = nil; return }
        // Named in the app language, like the day's meals, so the offer reads as the plate does.
        let history = await FoodLog.named((try? await store.foodLogEntries(from: Repository.localDayKey(start),
                                                                          to: Repository.localDayKey(yesterday))) ?? [])
        let found = FoodRepeat.suggestion(history: history, todayEntries: summary?.entries ?? [], today: day, now: .now)
        habit = found.flatMap { UserDefaults.standard.string(forKey: Self.habitDismissedKey) == Self.habitKey(day, $0.kind) ? nil : $0 }
    }

    private static let habitDismissedKey = "food.repeat.dismissed"
    private static func habitKey(_ day: String, _ kind: FoodLog.MealKind) -> String { "\(day):\(kind.rawValue)" }

    /// Logs the offered meal again, today at the time it was last eaten.
    func logHabit(repo: Repository) async {
        guard let habit else { return }
        // Today's plate is not yesterday's photo: the copy shows the group's picture.
        await copy(habit.entries.map { var entry = $0; entry.photoId = nil; return entry }, toDays: [day], repo: repo)
    }

    /// Hides the offer until the next meal time or the next day.
    func dismissHabit() {
        guard let habit else { return }
        UserDefaults.standard.set(Self.habitKey(day, habit.kind), forKey: Self.habitDismissedKey)
        self.habit = nil
    }

    /// The picture for a meal: its own photo, else the still life of its main food group.
    func picture(for meal: FoodLog.Meal) -> FoodMealPicture.Source? {
        if let id = meal.entries.lazy.compactMap(\.photoId).first { return .photo(id) }
        return FoodGroupMotif.forMeal(meal.entries, groups: groupsById).map { .motif($0) }
    }

    /// Pins or unpins a nutrient on the Food page (at most four; the oldest pin gives way).
    func togglePin(_ nutrient: FoodNutrient) {
        var list = pinned
        if let index = list.firstIndex(of: nutrient) { list.remove(at: index) } else { list.append(nutrient) }
        if list.count > 4 { list.removeFirst(list.count - 4) }
        UserDefaults.standard.set(list.map(\.rawValue).joined(separator: ","), forKey: FoodTargets.Keys.pinned)
        pinRevision += 1
    }
    /// Bumped on a pin change so views reading `pinned` refresh.
    private(set) var pinRevision = 0

    func shiftDay(by days: Int) {
        guard let date = WeightSeries.date(forDay: day),
              let next = Calendar.current.date(byAdding: .day, value: days, to: date) else { return }
        day = Repository.localDayKey(next)
    }

    /// When an entry added to this day is eaten: now on today, midday on another day.
    func defaultTime() -> Date {
        if isToday { return .now }
        let start = WeightSeries.date(forDay: day) ?? .now
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
    }

    // MARK: Actions

    @discardableResult
    func log(_ lines: [FoodCartLine], at: Date, meal: FoodLog.MealKind?, repo: Repository, coach: AICoachEngine?) async -> Bool {
        guard let store = await repo.storeHandle(), !lines.isEmpty else { return false }
        var items = lines.map(\.item)
        // A result found online is kept as the wearer's own food, so it is there offline next time.
        for index in items.indices where items[index].source == .online {
            if let saved = await FoodLibrary.saveOwn(store: store, items[index], origin: .online) { items[index] = saved }
        }
        // Missing vitamins and minerals, from the closest BLS food or the coach's estimate, only when chosen.
        if let coach, CoachFeaturePrefs.isEnabled, UserDefaults.standard.bool(forKey: FoodEstimate.enabledKey) {
            items = await coach.fillingMissingNutrients(items, store: store)
        }
        let origin: FoodLogEntry.Origin = items.contains { $0.source == .recipe } ? .recipe : .search
        let entries = zip(lines, items).map { line, item in
            FoodLog.entry(for: item, grams: line.grams, at: at, origin: origin, portionLabel: line.portionLabel, meal: meal,
                          photoId: line.photoId)
        }
        guard await FoodLog.save(store: store, entries) else { return false }
        await FoodHealthSync.wrote(entries, store: store)
        await reload(store: store)
        savedRevision += 1
        return true
    }

    @discardableResult
    func quick(_ quick: FoodQuickEntry, repo: Repository) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let entry = FoodLog.quickEntry(name: quick.name, kcal: quick.kcal, proteinG: quick.protein, carbsG: quick.carbs,
                                       fatG: quick.fat, at: quick.at)
        guard await FoodLog.save(store: store, [entry]) else { return false }
        await FoodHealthSync.wrote([entry], store: store)
        await reload(store: store)
        savedRevision += 1
        return true
    }

    func update(_ entry: FoodLogEntry, grams: Double?, at: Date?, meal: FoodLog.MealKind?, repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let next = FoodLog.edited(entry, grams: grams, at: at, meal: .some(meal))
        guard await FoodLog.save(store: store, [next]) else { return }
        await FoodHealthSync.replaced(old: entry, new: next, store: store)
        await reload(store: store)
    }

    /// What a correction to `item` can be applied to: the entries logged from that product in the last two weeks,
    /// under any of the ids it reaches the log under.
    func correctableEntries(for item: FoodItem, repo: Repository) async -> [FoodLogEntry] {
        guard let store = await repo.storeHandle() else { return [] }
        let ids = await FoodLibrary.logIds(store: store, for: item)
        return await FoodLog.recentEntries(store: store, foodIds: ids)
    }

    /// Keeps a corrected product as the wearer's own food, so it stands in for the row it came from everywhere,
    /// and restates the entries handed in. A restated entry keeps its amount, time and meal; its Health record is
    /// replaced, so Apple Health carries the corrected figures too.
    func correct(_ item: FoodItem, restating: [FoodLogEntry], repo: Repository) async -> FoodItem? {
        guard let store = await repo.storeHandle() else { return nil }
        let target = await FoodLibrary.correctionTarget(store: store, for: item)
        guard let kept = await FoodLibrary.saveOwn(store: store, target,
                                                   origin: target.source == .own ? .own : .online) else { return nil }
        let restated = restating.compactMap { FoodLog.restated($0, from: kept) }
        if !restated.isEmpty, await FoodLog.save(store: store, restated) {
            let byId = Dictionary(uniqueKeysWithValues: restating.map { ($0.id, $0) })
            for next in restated {
                guard let old = byId[next.id] else { continue }
                await FoodHealthSync.replaced(old: old, new: next, store: store)
            }
        }
        await reload(store: store)
        savedRevision += 1
        return kept
    }

    func delete(_ entries: [FoodLogEntry], repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        await FoodHealthSync.removed(await FoodLog.delete(store: store, ids: entries.map(\.id)))
        await reload(store: store)
    }

    func copy(_ entries: [FoodLogEntry], toDays days: [String], repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let copies = FoodLog.copies(of: entries, toDays: days)
        guard await FoodLog.save(store: store, copies) else { return }
        await FoodHealthSync.wrote(copies, store: store)
        await reload(store: store)
        savedRevision += 1
    }

    func makeRecipe(name: String, from entries: [FoodLogEntry], servings: Double, repo: Repository) async -> Bool {
        guard let store = await repo.storeHandle(),
              let recipe = FoodLog.recipe(name: name, from: entries, servings: servings) else { return false }
        return (try? await store.saveFoodRecipe(recipe)) ?? false
    }

    func setFavourite(_ item: FoodItem, on: Bool, repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        try? await store.setFoodFavourite(.init(foodId: item.id, name: item.name,
                                                addedAt: Int(Date.now.timeIntervalSince1970)), on: on)
    }
}
#endif
