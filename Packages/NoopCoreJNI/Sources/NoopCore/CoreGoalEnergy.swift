import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Profile and energy settings for the goal reader. No profile arithmetic lives in the Kotlin host.
enum CoreGoalEnergy {
    static func settings(_ args: [String: Any]) -> CoreGoals.Settings {
        let sex = args["sex"] as? String ?? ""
        let epoch = (args["lastSync"] as? NSNumber)?.doubleValue ?? 0
        var settings = CoreGoals.Settings(profileSex: sex,
            lastSync: epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil,
            agelessEnabled: args["ageless"] as? Bool ?? false,
            dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? [])
        if let raw = args["energyProfile"] as? [String: Any],
           let weight = raw["weightKg"] as? NSNumber, let height = raw["heightCm"] as? NSNumber,
           let age = raw["age"] as? NSNumber, let maxHR = raw["maxHR"] as? NSNumber,
           [weight.doubleValue, height.doubleValue, age.doubleValue, maxHR.doubleValue].allSatisfy({ $0.isFinite && $0 > 0 }) {
            let formula = BmrFormulaLog.decode(args["formulaLog"] as? String ?? "").current
            settings.energyProfile = UserProfile(weightKg: weight.doubleValue, heightCm: height.doubleValue,
                age: age.doubleValue, sex: sex, maxHR: maxHR.doubleValue, basalFormula: formula)
        }
        settings.energyCalibrationEnabled = args["energyCalibration"] as? Bool ?? false
        settings.hydrationEnabled = args["hydrationEnabled"] as? Bool ?? false
        if let json = args["journalCatalog"] as? String,
           let items = try? JSONDecoder().decode([JournalCatalogItem].self, from: Data(json.utf8)) {
            settings.journalAliases = JournalCatalogStore.aliasMap(items)
            settings.journalAliasOrder = JournalCatalogStore.aliasOrder(items)
        }
        if let value = args["manualVO2max"] as? NSNumber, value.doubleValue.isFinite, value.doubleValue > 0,
           let day = args["manualVO2maxDay"] as? String, day.count == 10 {
            let weight = (args["manualVO2maxWeightKg"] as? NSNumber)?.doubleValue
            settings.energyManualVO2 = .init(vo2max: value.doubleValue, day: day, weightKg: weight.flatMap { $0 > 0 ? $0 : nil })
        }
        settings.energyActivityLevel = (args["activityLevelOverride"] as? NSNumber)
            .flatMap { JurcaFitness.ActivityLevel(rawValue: $0.intValue) }
        return settings
    }

    @MainActor private static var lastStore: WhoopStore?
    @MainActor private static var repairedOn: (device: String, day: String)?
    private static let stepCache = EnergyStepMovementCache()

    /// Same missing-today repair gate as Repository.energySummaries, scoped to the active store.
    @MainActor
    static func repairToday(reader: StoreReader, settings: CoreGoals.Settings, dailyRows: [DailyMetric],
                            profile: UserProfile, now: Date) async {
        if lastStore !== reader.store { lastStore = reader.store; repairedOn = nil }
        let today = StoreReader.localDayKey(now)
        guard repairedOn?.device != reader.activeDeviceId || repairedOn?.day != today else { return }
        repairedOn = (reader.activeDeviceId, today)
        let inputs = EnergyModelRefresh.Inputs(dailyRows: dailyRows, manualVO2: settings.energyManualVO2,
            activityLevelOverride: settings.energyActivityLevel, calibrationEnabled: settings.energyCalibrationEnabled,
            refreshMaxDays: EnergyModelRefresh.refreshMaxDays, dismissedDetectedSpans: settings.dismissedWorkoutSpans,
            latestPeakMET: nil)
        _ = await EnergyModelRefresh.perform(reader: reader, days: 1, profile: profile, now: now,
                                             inputs: inputs, stepCache: stepCache)
    }
}
