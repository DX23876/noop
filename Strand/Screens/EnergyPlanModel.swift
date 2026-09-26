import Foundation
import SwiftUI
import StrandAnalytics
import WhoopStore

// MARK: - What the two energy pages know
//
// The rule this model exists to honour is `EnergyEngine`'s third: sources are CHOSEN per day and never
// summed, because two devices on one wrist measure the same body and adding them invents a person who
// burned twice. A planner deriving its own burn would be exactly that second computation.
//
// So this model computes NO burn. It reads `energySummaries` for what was measured and
// `AdaptiveExpenditureEngine` for what intake and weight change imply, and its only own arithmetic is
// the formula page — which answers a different question (what a published formula PREDICTS) rather than
// competing with a measurement.

@MainActor
final class EnergyPlanModel: ObservableObject {

    @Published private(set) var loaded = false
    @Published private(set) var burn = EnergyPlanning.measuredBurn(days: [])
    @Published private(set) var balance: AdaptiveExpenditureEstimate?
    @Published private(set) var metrics = BodyMetrics.empty
    @Published private(set) var intakeDays = 0
    /// Mean daily energy spent DIGESTING what was logged, over the days that logged anything.
    ///
    /// It sits here rather than in `DailyEnergySummary` on purpose: no wearable observes digestion, so
    /// folding it into the day's burn would change what that number means for every screen, the widget
    /// and the coach. On this page the question is balance — what came in against what went out — and
    /// there the term belongs.
    @Published private(set) var thermicEffectKcal: Double?
    @Published private(set) var today = Repository.localDayKey(Date())

    /// Today's balance: what was eaten against what the day is on course to cost. Nil until both
    /// halves exist — an intake figure and a burn forecast.
    @Published private(set) var todayBalance: EnergyPlanning.DailyBalance?
    /// What today's intake currently reads, from Health, a CSV import or typed in here. Nil means
    /// nothing has been logged for today, which the card says rather than guessing.
    @Published private(set) var todayIntakeKcal: Double?
    /// Today's projected total burn, so the card can show the denominator even before an intake
    /// figure exists.
    @Published private(set) var todayProjectedBurnKcal: Double?

    @Published var activity: ActivityLevel = EnergyPlanStore.activityLevel {
        didSet { EnergyPlanStore.activityLevel = activity }
    }
    @Published var targetKgPerWeek: Double = EnergyPlanStore.targetKgPerWeek {
        didSet { EnergyPlanStore.targetKgPerWeek = targetKgPerWeek }
    }

    /// The window both tiers report over. Thirty days is what `AdaptiveExpenditureEngine` needs to say
    /// anything at all, so using the same span keeps the two figures answering the same question.
    static let windowDays = 30

    func load(repo: Repository, profile: UserProfile) async {
        today = Repository.localDayKey(Date())
        metrics = await repo.bodyMetrics()

        let summaries = await repo.energySummaries(days: Self.windowDays, profile: profile)
        // Today is excluded: a day still in progress has a partial total, and averaging it in would
        // drag the mean down by however many hours are left.
        let days = summaries.filter { $0.day < today }.compactMap { summary -> BurnDay? in
            guard let total = summary.totalBurnedSoFar else { return nil }
            return BurnDay(day: summary.day, totalKcal: total, source: summary.source,
                           coverage: summary.coverage.energy)
        }
        burn = EnergyPlanning.measuredBurn(days: days)
        balance = await repo.adaptiveExpenditureEstimate()

        let from = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -Self.windowDays, to: Date()) ?? Date())
        let intake = await repo.intakeByDay(from: from, to: today)
        intakeDays = intake.count
        let macros = await repo.macrosByDay(from: from, to: today)
        let thermic = intake.compactMap { day, kcal in
            EnergyPlanning.thermicEffect(intakeKcal: kcal, proteinG: macros[day]?.protein,
                                         carbsG: macros[day]?.carbs, fatG: macros[day]?.fat)
        }
        thermicEffectKcal = thermic.isEmpty ? nil : thermic.reduce(0, +) / Double(thermic.count)

        await loadTodayBalance(repo: repo, profile: profile, intake: intake, macros: macros)
        loaded = true
    }

    /// Today's own numbers, kept apart from the 30-day averages above because they answer a
    /// different question: those describe a fortnight, this one describes the day in progress.
    ///
    /// The comparison is against the day's FORECAST, not against what has been burned so far. At two
    /// in the afternoon the burn-so-far is half a day and the food is most of one, so every
    /// afternoon would read as a surplus — a verdict that says more about the clock than the diet.
    private func loadTodayBalance(repo: Repository, profile: UserProfile,
                                  intake: [String: Double],
                                  macros: [String: (protein: Double?, carbs: Double?, fat: Double?)]) async {
        todayIntakeKcal = intake[today]
        let summary = await repo.todayEnergy(profile: profile)
        todayProjectedBurnKcal = summary?.projectedTotalBurn
        todayBalance = EnergyPlanning.dailyBalance(
            intakeKcal: intake[today],
            thermicKcal: EnergyPlanning.thermicEffect(intakeKcal: intake[today],
                                                      proteinG: macros[today]?.protein,
                                                      carbsG: macros[today]?.carbs,
                                                      fatG: macros[today]?.fat),
            projectedBurnKcal: summary?.projectedTotalBurn,
            projectedBurnRange: summary?.projectedRangeKcal)
    }

    /// Records what was eaten today and recomputes the verdict, without reloading the whole page.
    func recordTodayIntake(_ kcal: Double, repo: Repository, profile: UserProfile) async {
        guard await repo.recordIntake(kcal: kcal, on: today) else { return }
        let from = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -Self.windowDays, to: Date()) ?? Date())
        let intake = await repo.intakeByDay(from: from, to: today)
        intakeDays = intake.count
        await loadTodayBalance(repo: repo, profile: profile, intake: intake,
                               macros: await repo.macrosByDay(from: from, to: today))
    }

    /// The daily deficit or surplus the wearer's own target rate implies, or nil when they hold.
    var targetDailyKcal: Double? {
        guard targetKgPerWeek != 0 else { return nil }
        return EnergyPlanning.dailyEnergyDelta(targetKgPerWeek: targetKgPerWeek)
    }

    // MARK: - The formula page

    /// The formula every day is computed with (`BmrFormulaLog.current`).
    var currentFormula: BasalFormula { EnergyPlanStore.formulaLog.current }

    /// The body-fat figure in force today, whatever its source.
    var bodyFatToday: BodyReading? { metrics.asOf("body_fat", day: today) }

    /// The basal rate under `formula`, using today's body data.
    func basalRate(_ formula: BasalFormula, profile: UserProfile) -> Double? {
        BasalRate.kcalPerDay(formula,
                             weightKg: metrics.value("weight", on: today) ?? profile.weightKg,
                             heightCm: metrics.value("height", on: today) ?? profile.heightCm,
                             age: profile.age, sex: profile.sex,
                             bodyFatPercent: bodyFatToday?.value)
    }

    /// What the formula page predicts: basal rate times the stated activity convention.
    func formulaTdee(profile: UserProfile) -> Double? {
        guard let basal = basalRate(currentFormula, profile: profile) else { return nil }
        return EnergyPlanning.formulaTdee(basalKcal: basal, activity: activity)
    }

    /// How much switching to `formula` would move the daily basal rate. What the provenance sheet
    /// states, because an unexplained step of this size reads as a bug.
    func switchDelta(to formula: BasalFormula, profile: UserProfile) -> Double? {
        BasalRate.switchDelta(from: currentFormula, to: formula,
                              weightKg: metrics.value("weight", on: today) ?? profile.weightKg,
                              heightCm: metrics.value("height", on: today) ?? profile.heightCm,
                              age: profile.age, sex: profile.sex,
                              bodyFatPercent: bodyFatToday?.value)
    }

    /// Whether a formula can be selected at all today. Katch-McArdle needs a body-fat reading.
    func isAvailable(_ formula: BasalFormula) -> Bool {
        !formula.needsBodyFat || bodyFatToday != nil
    }

    // MARK: - The corridor

    func corridor(profile: UserProfile) -> EnergyCorridor {
        EnergyCorridor(formulaKcal: formulaTdee(profile: profile),
                       measuredKcal: burn.measuredMeanKcal ?? burn.allDaysMeanKcal,
                       balanceKcal: balance?.estimatedDailyKcal)
    }

    /// The wearer's own observed cost per kilogram, shown beside the Wishnofsky convention once the
    /// data supports it.
    var observedKcalPerKg: Double? {
        guard let balance, let measured = burn.measuredMeanKcal ?? burn.allDaysMeanKcal else {
            return nil
        }
        let days = Double(balance.windowDays)
        return EnergyPlanning.observedKcalPerKg(
            intakeKcal: balance.averageCaloriesIn * days, burnKcal: measured * days,
            weightChangeKg: balance.weightChangeKgPerDay * days)
    }

    /// The daily delta the target rate implies, under whichever cost per kilogram is available.
    func dailyDelta() -> Double? {
        EnergyPlanning.dailyEnergyDelta(targetKgPerWeek: targetKgPerWeek,
                                        kcalPerKg: observedKcalPerKg
                                            ?? EnergyPlanning.wishnofskyKcalPerKg)
    }
}
