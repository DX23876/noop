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
    @Published private(set) var today = Repository.localDayKey(Date())

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
        intakeDays = await repo.intakeByDay(from: from, to: today).count
        loaded = true
    }

    // MARK: - The formula page

    /// Which formula applies today, from the dated log.
    var currentFormula: BasalFormula { EnergyPlanStore.formulaLog.formula(onDay: today) }

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
