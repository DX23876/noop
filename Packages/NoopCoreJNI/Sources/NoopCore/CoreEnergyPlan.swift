import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The Energy Plan on Android (parity plan 2.3): what Apple's `EnergyPlanModel` loads and derives, over the core's
/// store. The day summaries, intake lanes and balance estimate are the shared reads; every figure the page shows
/// arrives computed, so the Kotlin screen only lays it out.
enum CoreEnergyPlan {
    static let windowDays = 30

    struct Output: Encodable {
        var today: String
        var available: Bool
        var measuredMeanKcal: Double?
        var allDaysMeanKcal: Double?
        var measuredDays: Int
        var totalDays: Int
        var burnQuality: String?
        var balanceIntakeDays: Int?
        var balanceKcal: Double?
        var balanceLowKcal: Double?
        var balanceHighKcal: Double?
        var balanceConfidence: String?
        var balanceWindowDays: Int?
        var intakeDays: Int
        var thermicEffectKcal: Double?
        var todayIntakeKcal: Double?
        var todayProteinG: Double?
        var todayCarbsG: Double?
        var todayFatG: Double?
        var todayProjectedBurnKcal: Double?
        var todayBalanceKcal: Double?
        var todayVerdict: String?
        var activity: String
        var targetKgPerWeek: Double
        var targetDailyKcal: Double?
        var dailyDeltaKcal: Double?
        var observedKcalPerKg: Double?
        var currentFormula: String
        var formulaTdeeKcal: Double?
        var formulas: [Formula]
        var corridorKcal: [Double]
        var corridorSpreadKcal: Double?
    }
    struct Formula: Encodable { var formula: String; var basalKcal: Double?; var available: Bool; var switchDeltaKcal: Double? }

    @MainActor
    static func plan(reader: StoreReader, settings: CoreGoals.Settings, activity: ActivityLevel, targetKgPerWeek: Double,
                     now: Date = Date()) async -> Output {
        let today = StoreReader.localDayKey(now)
        guard let profile = settings.energyProfile else {
            return Output(today: today, available: false, measuredDays: 0, totalDays: 0, intakeDays: 0,
                          activity: activity.rawValue, targetKgPerWeek: targetKgPerWeek, currentFormula: BasalFormula.revisedHarrisBenedict.rawValue,
                          formulas: [], corridorKcal: [])
        }
        let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 4_000)
        let balance = await NutritionReads.adaptiveEstimate(reader: reader, asOf: now)
        let from = StoreReader.localDayKey(now.addingTimeInterval(-Double(windowDays + 1) * 86_400))
        let daily = StoreReader.mergeDaily(imported: await reader.unionDailyMetrics(from: from, to: today),
                                           computed: await reader.unionComputedDailyMetrics(from: from, to: today))
        // Logged sessions as the Apple summaries read them: one row per session, heart-rate fills overlaid.
        let raw = await reader.rawWorkoutRows(from: Int(now.timeIntervalSince1970) - (windowDays + 2) * 86_400,
            to: Int(now.timeIntervalSince1970) + 86_400, dismissedDetectedSpans: settings.dismissedWorkoutSpans)
        let workouts = await WorkoutHeartRateFills.overlay(WorkoutSource.dedupCrossSource(raw).sorted { $0.startTs > $1.startTs },
                                                           store: reader.store)
        let shape = await EnergySummaryStoreReads.activityShape(reader: reader, now: now)
        let summaries = await EnergySummaryStoreReads.summaries(reader: reader, days: windowDays, dailyRows: daily,
            workouts: workouts, profile: profile, hrMax: profile.maxHR, calibrationEnabled: settings.energyCalibrationEnabled,
            now: now, shape: shape, adaptivePrior: balance?.estimatedDailyKcal) {
            await CoreGoalEnergy.repairToday(reader: reader, settings: settings, dailyRows: daily, profile: profile, now: now)
        }
        // Today is excluded: a day still in progress has a partial total.
        let burn = EnergyPlanning.measuredBurn(days: summaries.filter { $0.day < today }.compactMap { s in
            s.totalBurnedSoFar.map { BurnDay(day: s.day, totalKcal: $0, source: s.source, coverage: s.coverage.energy) }
        })
        let nutrition = await NutritionReads.nutritionByDay(store: reader.store,
            from: StoreReader.localDayKey(now.addingTimeInterval(-Double(windowDays) * 86_400)), to: today)
        let intake = nutrition.compactMapValues(\.calories)
        let thermic = intake.compactMap { day, kcal in
            EnergyPlanning.thermicEffect(intakeKcal: kcal, proteinG: nutrition[day]?.proteinG,
                                         carbsG: nutrition[day]?.carbsG, fatG: nutrition[day]?.fatG)
        }
        let todayNutrition = nutrition[today]
        let todaySummary = summaries.last { $0.day == today }
        let todayBalance = EnergyPlanning.dailyBalance(
            intakeKcal: todayNutrition?.calories,
            thermicKcal: EnergyPlanning.thermicEffect(intakeKcal: todayNutrition?.calories, proteinG: todayNutrition?.proteinG,
                                                      carbsG: todayNutrition?.carbsG, fatG: todayNutrition?.fatG),
            projectedBurnKcal: todaySummary?.projectedTotalBurn, projectedBurnRange: todaySummary?.projectedRangeKcal)

        // The formula page and the corridor, as `EnergyPlanModel` derives them from today's body data.
        let current = profile.basalFormula
        let weight = metrics.value("weight", on: today) ?? profile.weightKg
        let height = metrics.value("height", on: today) ?? profile.heightCm
        let bodyFat = metrics.asOf("body_fat", day: today)?.value
        func basal(_ f: BasalFormula) -> Double? {
            BasalRate.kcalPerDay(f, weightKg: weight, heightCm: height, age: profile.age, sex: profile.sex, bodyFatPercent: bodyFat)
        }
        let formulaTdee = basal(current).flatMap { EnergyPlanning.formulaTdee(basalKcal: $0, activity: activity) }
        let corridor = EnergyCorridor(formulaKcal: formulaTdee, measuredKcal: burn.measuredMeanKcal ?? burn.allDaysMeanKcal,
                                      balanceKcal: balance?.estimatedDailyKcal)
        var observed: Double?
        if let balance, let measured = burn.measuredMeanKcal ?? burn.allDaysMeanKcal {
            let days = Double(balance.windowDays)
            observed = EnergyPlanning.observedKcalPerKg(intakeKcal: balance.averageCaloriesIn * days, burnKcal: measured * days,
                                                        weightChangeKg: balance.weightChangeKgPerDay * days)
        }
        return Output(
            today: today, available: true,
            measuredMeanKcal: burn.measuredMeanKcal, allDaysMeanKcal: burn.allDaysMeanKcal,
            measuredDays: burn.measuredDays, totalDays: burn.totalDays, burnQuality: burn.quality.rawValue,
            balanceIntakeDays: balance?.intakeDays,
            balanceKcal: balance?.estimatedDailyKcal, balanceLowKcal: balance?.lowerBoundKcal, balanceHighKcal: balance?.upperBoundKcal,
            balanceConfidence: balance.map { "\($0.confidence)" }, balanceWindowDays: balance?.windowDays,
            intakeDays: intake.count, thermicEffectKcal: thermic.isEmpty ? nil : thermic.reduce(0, +) / Double(thermic.count),
            todayIntakeKcal: todayNutrition?.calories, todayProteinG: todayNutrition?.proteinG,
            todayCarbsG: todayNutrition?.carbsG, todayFatG: todayNutrition?.fatG,
            todayProjectedBurnKcal: todaySummary?.projectedTotalBurn,
            todayBalanceKcal: todayBalance?.balanceKcal, todayVerdict: todayBalance.map { "\($0.verdict)" },
            activity: activity.rawValue, targetKgPerWeek: targetKgPerWeek,
            targetDailyKcal: targetKgPerWeek == 0 ? nil : EnergyPlanning.dailyEnergyDelta(targetKgPerWeek: targetKgPerWeek),
            dailyDeltaKcal: EnergyPlanning.dailyEnergyDelta(targetKgPerWeek: targetKgPerWeek,
                                                            kcalPerKg: observed ?? EnergyPlanning.wishnofskyKcalPerKg),
            observedKcalPerKg: observed, currentFormula: current.rawValue, formulaTdeeKcal: formulaTdee,
            formulas: BasalFormula.allCases.map { f in
                Formula(formula: f.rawValue, basalKcal: basal(f), available: !f.needsBodyFat || bodyFat != nil,
                        switchDeltaKcal: BasalRate.switchDelta(from: current, to: f, weightKg: weight, heightCm: height,
                                                               age: profile.age, sex: profile.sex, bodyFatPercent: bodyFat))
            },
            corridorKcal: corridor.present, corridorSpreadKcal: corridor.spreadKcal)
    }

    /// Records today's intake (a typed zero means "ate nothing"), keeping any macros already entered.
    static func recordIntake(store: WhoopStore, kcal: Double, now: Date = Date()) async -> Bool {
        let today = StoreReader.localDayKey(now)
        let existing = await NutritionReads.manualNutrition(store: store, on: today)
        return await NutritionReads.recordManualNutrition(store: store, .init(
            day: today, calories: kcal, proteinG: kcal == 0 ? nil : existing?.proteinG,
            carbsG: kcal == 0 ? nil : existing?.carbsG, fatG: kcal == 0 ? nil : existing?.fatG, isConfirmedNoIntake: kcal == 0))
    }
}
