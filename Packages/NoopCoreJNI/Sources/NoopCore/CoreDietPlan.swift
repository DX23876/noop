import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The diet planner on Android (decision 2026-11-09): the plan's targets, forecast, suggestions and weekly look,
/// all from the shared `DietTargets`, `DietForecast`, `DietSuggest` and `DietAdjust`. Kotlin stores the plan as the
/// same JSON under the same key as iOS and passes it in; nothing here is stored.
enum CoreDietPlan {
    struct Resolved: Encodable {
        var result: DietTargets.Result
        var forecast: DietForecast.Forecast
        /// The goal for the asked day (a fasting day has its own) and its macros.
        var dayKcal: Double
        var dayMacros: FoodTargets.Macros
    }

    /// `DietProgress.Progress` on the wire: `kind` is way, hold or recomp, with that case's fields beside it.
    struct ProgressWire: Encodable {
        var kind: String
        var goal: String?
        var startKg: Double
        var trendKg: Double
        var goalKg: Double?
        var fraction: Double?
        var stage: String?
        var doneKg: Double?
        var leftKg: Double?
        var inRange: Bool?
        var weeksInRange: Int?
        var weightSteady: Bool?
        var working: Bool?
        var bodyFatChange: Double?
        var waistChangeCm: Double?
        var strengthChangePercent: Double?

        init(_ p: DietProgress.Progress) {
            switch p {
            case .way(let w):
                kind = "way"; goal = w.goal.rawValue; startKg = w.startKg; trendKg = w.trendKg; goalKg = w.goalKg
                fraction = w.fraction; stage = w.stage.rawValue; doneKg = w.doneKg; leftKg = w.leftKg
            case .hold(let h):
                kind = "hold"; startKg = h.startKg; trendKg = h.trendKg; inRange = h.inRange; weeksInRange = h.weeksInRange
            case .recomp(let r):
                kind = "recomp"; startKg = r.startKg; trendKg = r.trendKg; weightSteady = r.weightSteady; working = r.working
                bodyFatChange = r.bodyFatChange; waistChangeCm = r.waistChangeCm; strengthChangePercent = r.strengthChangePercent
            }
        }
    }

    /// One day of the plan as the Food page shows it (`DietDayResolver`), with the reads iOS's `ForgeFoodModel` makes.
    struct DayWire: Encodable {
        var result: DietTargets.Result
        var dayKcal: Double
        var dayMacros: FoodTargets.Macros
        var phase: String
        var activeBonusKcal: Double
        var isTrainingDay: Bool
        var planBurnKcal: Double
        var dayComplete: Bool
        /// `estimate` with the real burn, or `missing` with what it still needs.
        var expenditure: String
        var realBurnKcal: Double?
        var realBurnLowKcal: Double?
        var realBurnHighKcal: Double?
        var strapKcal: Double?
        var trendKgPerWeek: Double?
        var completeDays: Int
        var weighIns: Int?
        /// iOS shows "Training day" or "Rest day" only when the plan shifts calories and the week mixes both.
        var showsTrainingLabel: Bool
        /// iOS names the active-day extra once it reaches `DietActiveDay.shownFromKcal`.
        var showsActiveBonus: Bool
        /// What the real burn needs (`DietExpenditure.minCompleteDays`, `minWeighIns`), for the card that says so.
        var needCompleteDays = DietExpenditure.minCompleteDays
        var needWeighIns = DietExpenditure.minWeighIns
    }

    /// The resolved strength history (imports and NOOP's own sessions) of the last year.
    static func strengthHistory(reader: StoreReader, dismissed: [String], now: Int) async -> ResolvedStrengthHistory {
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - 365 * 86_400, to: now + 86_400,
                                                        dismissedDetectedSpans: dismissed)
        return await StrengthHistoryReader.read(store: reader.store, days: 365, now: now) { fusion }
    }

    /// The strength days the plan counts as training: logged strength work and the planner's strength or hard sessions.
    static func trainingDays(reader: StoreReader, dismissed: [String], now: Int,
                             history known: ResolvedStrengthHistory? = nil) async -> DietTrainingDays {
        let history: ResolvedStrengthHistory
        if let known { history = known } else { history = await strengthHistory(reader: reader, dismissed: dismissed, now: now) }
        let offset = TimeZone.current.secondsFromGMT()
        let logged = Set(TrainingLoadLanes.strengthByDay(history.workouts, tzOffsetSeconds: offset).filter { $0.value > 0 }.keys)
        let planned = await MainActor.run { DietTrainingPlan.days(from: CoachPlanStore.shared.proposals) }
        return DietTrainingDays(planned: planned, logged: logged)
    }

    /// The main lifts' change since `since`, as iOS's `ForgeFoodModel` reads it for the plan.
    static func strengthChange(_ history: ResolvedStrengthHistory, since: String) -> Double? {
        StrengthSession.mainLiftChangePercent(workouts: history.workouts, templates: history.templates, since: since,
                                              tzOffsetSeconds: TimeZone.current.secondsFromGMT())
    }

    /// One day of the plan with the reads iOS's `ForgeFoodModel` makes for it, shared by the day and the suggestions.
    struct DayContext {
        var day: DietDayResolver.Day
        var person: DietPerson
        var complete: Set<String>
        var weights: [(day: String, kg: Double)]
        var history: ResolvedStrengthHistory
    }

    static func dayContext(plan: DietPlan, person: DietPerson, burn: Double, kcalPerKg: Double?, args: [String: Any],
                           store: WhoopStore, reader: StoreReader, day: String) async -> DayContext {
        let today = StoreReader.localDayKey(Date())
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(DietExpenditure.windowDays - 1), to: now)
            .map(StoreReader.localDayKey) ?? today
        let complete = (try? await store.foodCompleteDays(from: from, to: today)) ?? []
        let intake = (await NutritionReads.nutritionByDay(store: store, from: from, to: today)).compactMapValues { $0.calories }
        let weighFrom = Calendar.current.date(byAdding: .day, value: -120, to: now).map(StoreReader.localDayKey) ?? today
        let weights = await WeightSeries.series(reader: reader, from: weighFrom, to: today).map { (day: $0.day, kg: $0.value) }
        var burned: [String: Double] = [:]
        for (k, v) in args["burnedByDay"] as? [String: Any] ?? [:] { if let n = v as? NSNumber { burned[k] = n.doubleValue } }
        var withFat = person
        let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 365)
        withFat.bodyFatPercent = metrics.latest("body_fat")?.value
        let nowSec = Int(now.timeIntervalSince1970)
        let dismissed = args["dismissedWorkouts"] as? [String] ?? []
        let history = await strengthHistory(reader: reader, dismissed: dismissed, now: nowSec)
        let training = await trainingDays(reader: reader, dismissed: dismissed, now: nowSec, history: history)
        let inputs = DietDayResolver.Inputs(plan: plan, person: withFat, strapBurnKcal: burn, kcalPerKg: kcalPerKg,
                                            burnedByDay: burned, completeDays: complete, intakeByDay: intake,
                                            weighIns: weights, training: training, today: today)
        return DayContext(day: DietDayResolver.resolve(inputs, day: day, now: now), person: withFat,
                          complete: complete, weights: weights, history: history)
    }

    /// The week a dismissed suggestion belongs to: this week's Monday, as iOS's `ForgeFoodModel.adviceWeek`.
    static var adviceWeek: String {
        var c = Calendar.current; c.firstWeekday = 2
        return StoreReader.localDayKey(c.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date())
    }

    /// This week's suggestions for the plan (`DietAdvice`) from the same inputs iOS's `ForgeFoodModel.loadAdvice` reads.
    static func advice(plan: DietPlan, context ctx: DayContext, kcalPerKg: Double?, dismissedRaw: [String],
                       store: WhoopStore) async -> (suggestions: [DietAdvice.Suggestion], proteinMeanG: Double?) {
        let cal = Calendar.current
        func key(_ back: Int) -> String { StoreReader.localDayKey(cal.date(byAdding: .day, value: -back, to: Date()) ?? Date()) }
        let today = key(0)
        let main = DietTargets.resolve(plan, person: ctx.person, burnKcal: ctx.day.planBurnKcal, kcalPerKg: kcalPerKg)
        let days21 = await FoodLog.totals(store: store, from: key(20), to: today).filter { !$0.totals.isEmpty }
        let last7 = days21.filter { $0.day >= key(6) }
        let proteins = last7.compactMap { $0.totals[.proteinG] }
        let weights7 = ctx.weights.filter { $0.day >= key(6) }.count
        let trend = DietAdjust.slopePerWeek(ctx.weights.filter { $0.day >= key(20) })
        let age = WeightSeries.date(forDay: plan.startDay).flatMap { cal.dateComponents([.day], from: $0, to: Date()).day } ?? 0
        let proteinMean = proteins.isEmpty ? nil : proteins.reduce(0, +) / Double(proteins.count)
        let inputs = DietAdvice.Inputs(goal: main.goal, proteinMeanG: proteinMean, proteinGoalG: main.proteinG,
                                       weighInsLast7: weights7, loggedDaysLast7: last7.count,
                                       strengthChange4WeeksPercent: strengthChange(ctx.history, since: key(28)),
                                       trend3WeeksKgPerWeek: trend, loggedDaysLast21: days21.count,
                                       inBreakOrHolding: ctx.day.phase != .main, planAgeDays: age)
        let week = adviceWeek
        let dismissed = Set(dismissedRaw.filter { $0.hasPrefix(week + ":") }
            .compactMap { DietAdvice.Kind(rawValue: String($0.dropFirst(week.count + 1))) })
        return (DietAdvice.suggestions(inputs, dismissed: dismissed), proteinMean)
    }

    static func run(_ op: String, args: [String: Any], store: WhoopStore, reader: StoreReader) async -> String {
        func double(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        let sex = (args["sex"] as? String ?? "").lowercased()
        let person = DietPerson(weightKg: double("weightKg") ?? 80, heightCm: double("heightCm").flatMap { $0 > 0 ? $0 : nil },
                                age: (args["age"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                                male: sex == "male" ? true : sex == "female" ? false : nil)
        let burn = double("burnKcal") ?? person.weightKg * 30
        let kcalPerKg = double("kcalPerKg")
        let today = StoreReader.localDayKey(Date())

        switch op {
        case "food.planResolve":
            guard let plan = DietPlan.decode(args["plan"] as? String) else { return "null" }
            let result = DietTargets.resolve(plan, person: person, burnKcal: burn, kcalPerKg: kcalPerKg)
            let day = args["day"] as? String ?? today
            let forecast = DietForecast.project(startKg: person.weightKg, goalKg: result.goalWeightKg, intakeKcal: result.averageKcal,
                                                burnKcal: result.burnKcal, kcalPerKg: kcalPerKg ?? DietTargets.defaultKcalPerKg,
                                                dietBreakEveryWeeks: DietProgram.dietBreakEveryWeeks(plan))
            return CoreRead.json(Resolved(result: result, forecast: forecast,
                                          dayKcal: DietTargets.kcal(on: day, plan: plan, result: result),
                                          dayMacros: FoodTargets.macros(plan: plan, result: result, day: day)))
        case "food.planDay":
            guard let plan = DietPlan.decode(args["plan"] as? String) else { return "null" }
            let day = args["day"] as? String ?? today
            let ctx = await dayContext(plan: plan, person: person, burn: burn, kcalPerKg: kcalPerKg, args: args,
                                       store: store, reader: reader, day: day)
            let r = ctx.day
            let complete = ctx.complete
            let training = await trainingDays(reader: reader, dismissed: args["dismissedWorkouts"] as? [String] ?? [],
                                              now: Int(Date().timeIntervalSince1970), history: ctx.history)
            let isComplete = ((try? await store.foodCompleteDays(from: day, to: day)) ?? []).contains(day)
            var wire = DayWire(result: r.result, dayKcal: r.calories.kcal, dayMacros: r.macros, phase: r.phase.rawValue,
                               activeBonusKcal: r.activeBonusKcal, isTrainingDay: r.isTrainingDay, planBurnKcal: r.planBurnKcal,
                               dayComplete: isComplete, expenditure: "missing", completeDays: complete.count,
                               showsTrainingLabel: plan.effectiveDayShift > 0
                                   && (1...6).contains(DietTargets.weekTrainingCount(day, plan: plan, training: training)),
                               showsActiveBonus: r.activeBonusKcal >= DietActiveDay.shownFromKcal)
            switch r.expenditure {
            case .estimate(let e):
                wire.expenditure = "estimate"; wire.realBurnKcal = e.burnKcal
                wire.realBurnLowKcal = e.rangeKcal.lowerBound; wire.realBurnHighKcal = e.rangeKcal.upperBound
                wire.strapKcal = e.strapKcal; wire.trendKgPerWeek = e.trendKgPerWeek; wire.completeDays = e.completeDays
            case .missing(let days, let weighIns):
                wire.completeDays = days; wire.weighIns = weighIns
            }
            return CoreRead.json(wire)
        case "food.planAdvice":
            // This week's suggestions on the plan page (iOS `DietAdviceCard`): kind and action, at most three, without
            // those dismissed this week. `dismissed` holds the stored "week:kind" entries under iOS's key.
            guard let plan = DietPlan.decode(args["plan"] as? String) else { return "null" }
            let ctx = await dayContext(plan: plan, person: person, burn: burn, kcalPerKg: kcalPerKg, args: args,
                                       store: store, reader: reader, day: today)
            let a = await advice(plan: plan, context: ctx, kcalPerKg: kcalPerKg,
                                 dismissedRaw: args["dismissed"] as? [String] ?? [], store: store)
            struct Item: Encodable { var kind: String; var action: String }
            struct Source: Encodable { var group: String; var grams: Int }
            struct Wire: Encodable {
                var suggestions: [Item]; var proteinMeanG: Double?; var week: String
                /// The protein page: the plan's goal, the groups the plan allows and the portions that close the gap.
                var proteinGoalG: Double; var proteinFoods: [Source]; var proteinPortions: Int
            }
            let goalG = DietTargets.resolve(plan, person: ctx.person, burnKcal: ctx.day.planBurnKcal, kcalPerKg: kcalPerKg).proteinG
            return CoreRead.json(Wire(suggestions: a.suggestions.map { Item(kind: $0.kind.rawValue, action: $0.action.rawValue) },
                                      proteinMeanG: a.proteinMeanG, week: adviceWeek, proteinGoalG: goalG,
                                      proteinFoods: DietProteinSources.groups(addon: plan.addon)
                                          .map { Source(group: $0.group.rawValue, grams: $0.grams) },
                                      proteinPortions: a.proteinMeanG.map { DietProteinSources.portionsToClose(goalG: goalG, meanG: $0) } ?? 0))
        case "food.planApplyAdvice":
            // The plan after taking a suggestion that changes it (`DietAdvice.applying`); null for one that opens a page.
            guard let plan = DietPlan.decode(args["plan"] as? String),
                  let kind = DietAdvice.Kind(rawValue: args["kind"] as? String ?? ""),
                  let action = DietAdvice.Action(rawValue: args["action"] as? String ?? ""),
                  let next = DietAdvice.applying(.init(kind: kind, action: action), to: plan, today: today),
                  let text = next.encoded() else { return "null" }
            return text
        case "food.planTraining":
            // The planner's training-day step: the planner's sessions in the coming week and the usual weekdays
            // from logged strength training (`DietTrainingDays.usualWeekdays`), as iOS's `ForgeFoodModel` reads them.
            let now = Date()
            let training = await trainingDays(reader: reader, dismissed: args["dismissedWorkouts"] as? [String] ?? [],
                                              now: Int(now.timeIntervalSince1970))
            let until = Calendar.current.date(byAdding: .day, value: 6, to: now).map(StoreReader.localDayKey) ?? today
            let planned = training.planned.filter { $0 >= today && $0 <= until }.sorted()
            struct Wire: Encodable { var plannedThisWeek: [String]; var usualWeekdays: [Int] }
            return CoreRead.json(Wire(plannedThisWeek: planned, usualWeekdays: DietTrainingDays.usualWeekdays(logged: training.logged)))
        case "food.planDayComplete":
            // Whether a day is marked as completely logged; the Food page shows the mark with or without a plan.
            let day = args["day"] as? String ?? today
            let marked = ((try? await store.foodCompleteDays(from: day, to: day)) ?? []).contains(day)
            return #"{"complete":\#(marked)}"#
        case "food.planSetDayComplete":
            // Only completely logged days count toward the real burn.
            try? await store.setFoodDayComplete(args["day"] as? String ?? today, args["complete"] as? Bool ?? true)
            return #"{"ok":true}"#
        case "food.planSuggest":
            let from = Calendar.current.date(byAdding: .day, value: -14, to: Date()).map(StoreReader.localDayKey) ?? today
            let entries = ((try? await store.foodLogEntries(from: from, to: today)) ?? []).map(FoodLogEntryLite.init)
            let keep = (args["keep"] as? [String] ?? []).compactMap(DietPlan.Keep.init(rawValue:))
            let mode = DietPlan.Mode(rawValue: args["mode"] as? String ?? "") ?? .simple
            let s = DietSuggest.top(entries: entries, keep: keep, likesRules: args["likesRules"] as? Bool ?? false,
                                    strength: args["strength"] as? Bool ?? false, mode: mode)
            return CoreRead.json(["suggestions": s])
        case "food.planWeekly":
            guard let plan = DietPlan.decode(args["plan"] as? String) else { return "null" }
            let result = DietTargets.resolve(plan, person: person, burnKcal: burn, kcalPerKg: kcalPerKg)
            let from = Calendar.current.date(byAdding: .day, value: -21, to: Date()).map(StoreReader.localDayKey) ?? today
            let weights = await WeightSeries.series(reader: reader, from: from, to: today).map { (day: $0.day, kg: $0.value) }
            let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()).map(StoreReader.localDayKey) ?? today
            let logged = Set(((try? await store.foodLogEntries(from: weekStart, to: today)) ?? []).map(\.day)).count
            let outcome = DietAdjust.weekly(plan: plan, result: result, weighIns: weights, loggedDays: logged, today: today,
                                            kcalPerKg: kcalPerKg ?? DietTargets.defaultKcalPerKg)
            return CoreRead.json(outcome)
        case "food.planProgress":
            // The way to the goal weight (`DietProgress`), as the plan page and Today's diet goal card show it: the
            // goal weight as planned, the smoothed weight trend, and for recomposition body fat and the waist.
            guard let plan = DietPlan.decode(args["plan"] as? String), !plan.hideNumbers else { return "null" }
            let from = Calendar.current.date(byAdding: .day, value: -120, to: Date()).map(StoreReader.localDayKey) ?? today
            let weights = await WeightSeries.series(reader: reader, from: from, to: today).map { (day: $0.day, kg: $0.value) }
            var bodyFat: [(day: String, value: Double)] = []
            var waist: [(day: String, value: Double)] = []
            var strength: Double?
            if args["body"] as? Bool == true {
                let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 365)
                bodyFat = metrics.series("body_fat").map { ($0.day, $0.value) }
                waist = metrics.series("waist").map { ($0.day, $0.value) }
                // iOS's plan page also weighs the main lifts since the plan began for recomposition.
                let history = await strengthHistory(reader: reader, dismissed: args["dismissedWorkouts"] as? [String] ?? [],
                                                    now: Int(Date().timeIntervalSince1970))
                strength = strengthChange(history, since: plan.startDay)
            }
            guard let progress = DietProgress.resolve(plan: plan, goalWeightKg: DietTargets.plannedGoalWeight(plan, person: person),
                                                      weighIns: weights, bodyFat: bodyFat, waist: waist,
                                                      strengthChangePercent: strength) else { return "null" }
            return CoreRead.json(ProgressWire(progress))
        case "food.planFit":
            // Whether a food (by id or stored group) suits the plan: 1 suits, -1 kept rare, 0 neutral.
            guard let plan = DietPlan.decode(args["plan"] as? String),
                  let motif = FoodGroupMotif.forFoodId(args["foodId"] as? String) ?? FoodGroupMotif.forGroup(args["group"] as? String)
            else { return #"{"fit":0}"# }
            return #"{"fit":\#(plan.form.fit(motif, addon: plan.addon))}"#
        default:
            return #"{"error":"unknownOp"}"#
        }
    }
}
