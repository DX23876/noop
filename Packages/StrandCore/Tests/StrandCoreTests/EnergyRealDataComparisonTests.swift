import XCTest
import StrandAnalytics
import WhoopStore
@testable import StrandCore

/// The owner's check before a testing build (decision 2026-11-27, Q17): the energy model run over a copy of a
/// real store, the stored generation against the new one day by day. Skipped unless `NOOP_ENERGY_REAL_DB`
/// names a COPY of a store (the run writes the new generation into it). Prints a table and fails when a day
/// moves by more than a third, which no allowance of this size can explain.
///
///     NOOP_ENERGY_REAL_DB=/path/to/copy/whoop.sqlite NOOP_ENERGY_NOW=2026-11-22T23:00:00Z \
///         NOOP_ENERGY_WEIGHT=200.2 NOOP_ENERGY_HEIGHT=196 NOOP_ENERGY_AGE=35 NOOP_ENERGY_SEX=male \
///         swift test --filter EnergyRealDataComparisonTests
final class EnergyRealDataComparisonTests: XCTestCase {
    func testTheNewGenerationAgainstTheStoredOne() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NOOP_ENERGY_REAL_DB"] else { throw XCTSkip("NOOP_ENERGY_REAL_DB not set") }
        let deviceId = env["NOOP_ENERGY_DEVICE"] ?? "my-whoop"
        let now = env["NOOP_ENERGY_NOW"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let profile = UserProfile(weightKg: Double(env["NOOP_ENERGY_WEIGHT"] ?? "") ?? 80,
                                  heightCm: Double(env["NOOP_ENERGY_HEIGHT"] ?? "") ?? 180,
                                  age: Double(env["NOOP_ENERGY_AGE"] ?? "") ?? 35,
                                  sex: env["NOOP_ENERGY_SEX"] ?? "male",
                                  maxHR: env["NOOP_ENERGY_MAXHR"].flatMap(Double.init),
                                  basalFormula: .mifflinStJeor)
        let store = try await WhoopStore(path: path)
        let reader = StoreReader(store: store, activeDeviceId: deviceId, registeredWhoopIds: [deviceId])
        let days = 120
        let to = StoreReader.localDayKey(now)
        let from = StoreReader.localDayKey(now.addingTimeInterval(-Double(days) * 86_400))

        func activeByDay() async throws -> [String: Double] {
            var out: [String: Double] = [:]
            for row in try await store.whoopEnergyHours(deviceId: deviceId, from: from, to: to) {
                out[row.day, default: 0] += row.activeKcal
            }
            return out
        }
        let oldRows = Dictionary(try await store.whoopDailyEnergy(deviceId: deviceId, from: from, to: to)
            .map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let oldActive = try await activeByDay()

        let dailyRows = await reader.unionDailyMetrics(from: StoreReader.localDayKey(
            now.addingTimeInterval(-Double(days + 30) * 86_400)), to: to)
        let inputs = EnergyModelRefresh.Inputs(dailyRows: dailyRows, manualVO2: nil, activityLevelOverride: nil,
                                               calibrationEnabled: false, refreshMaxDays: days,
                                               dismissedDetectedSpans: [], latestPeakMET: nil)
        let outcome = await EnergyModelRefresh.perform(reader: reader, days: days, profile: profile, now: now,
                                                       inputs: inputs, stepCache: EnergyStepMovementCache())
        XCTAssertTrue(outcome.ok)
        let newRows = Dictionary(try await store.whoopDailyEnergy(deviceId: deviceId, from: from, to: to)
            .map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let newActive = try await activeByDay()

        /// A day's total as the engine reads it: basal for the whole day at the day's weight, plus the
        /// everyday share and the active energy.
        func dayTotal(_ row: WhoopDailyEnergyRow, active: Double) -> Double {
            var dayProfile = profile
            dayProfile.weightKg = row.weightKg
            let bmr = Calories.bmrKcalPerDay(profile: dayProfile) ?? 0
            return bmr + WhoopEnergyModel.everydayKcal(basalPerSecond: bmr / 86_400,
                                                       seconds: Double(row.everydaySeconds)) + active
        }
        var lines = ["day         old kg  new kg   old kcal  new kcal   change  everyday  PAL old  PAL new"]
        var ratios: [Double] = []
        var outliers: [String] = []
        for day in newRows.keys.sorted() where day < to {
            guard let new = newRows[day], new.modelVersion == WhoopDailyEnergyEstimate.modelVersion,
                  let old = oldRows[day] else { continue }
            let before = dayTotal(old, active: oldActive[day] ?? 0)
            let after = dayTotal(new, active: newActive[day] ?? 0)
            var weighed = profile
            weighed.weightKg = new.weightKg
            let bmr = Calories.bmrKcalPerDay(profile: weighed) ?? 1
            var weighedOld = profile
            weighedOld.weightKg = old.weightKg
            let bmrOld = Calories.bmrKcalPerDay(profile: weighedOld) ?? 1
            let ratio = after / max(1, before)
            ratios.append(ratio)
            if ratio > 4.0 / 3 || ratio < 0.75 { outliers.append(day) }
            lines.append(String(format: "%@  %6.1f  %6.1f  %9.0f %9.0f  %+7.0f  %8.0f  %7.2f  %7.2f", day,
                                old.weightKg, new.weightKg, before, after, after - before,
                                WhoopEnergyModel.everydayKcal(basalPerSecond: bmr / 86_400,
                                                              seconds: Double(new.everydaySeconds)),
                                before / bmrOld, after / bmr))
        }
        let mean = ratios.isEmpty ? 0 : ratios.reduce(0, +) / Double(ratios.count)
        lines.append(String(format: "days %d, mean change x%.3f, outliers %@", ratios.count, mean,
                            outliers.joined(separator: ", ")))
        print(lines.joined(separator: "\n"))
        XCTAssertTrue(outliers.isEmpty, "days moved by more than a third: \(outliers)")
    }
}
