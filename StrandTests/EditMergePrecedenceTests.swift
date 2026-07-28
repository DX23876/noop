import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// H5 (#509): a night the user hand-edited must keep its corrected SLEEP figures even when a WHOOP/Apple
/// import also covers that day — `Repository.mergeDaily(userEditedDays:)` lets the COMPUTED row's sleep
/// fields win on those days while imports still win everywhere else. Pure (no store).
final class EditMergePrecedenceTests: XCTestCase {

    /// On an EDITED day, computed sleep fields win over the import; non-sleep fields still follow imports.
    func testEditedDayComputedSleepWins() {
        let imported = full(day: "2026-06-12", totalSleepMin: 480, deepMin: 90, remMin: 110,
                            lightMin: 280, efficiency: 0.92, recovery: 80, strain: 9.0)
        // The user shortened the night by hand → the computed (edit-derived) row has the corrected totals.
        let computed = full(day: "2026-06-12", totalSleepMin: 300, deepMin: 50, remMin: 70,
                            lightMin: 180, efficiency: 0.85, recovery: 55, strain: 14.0)

        let merged = Repository.mergeDaily(imported: [imported], computed: [computed],
                                           userEditedDays: ["2026-06-12"])

        XCTAssertEqual(merged.count, 1)
        // Sleep fields: computed (the edit) wins.
        XCTAssertEqual(merged[0].totalSleepMin, 300)
        XCTAssertEqual(merged[0].deepMin, 50)
        XCTAssertEqual(merged[0].remMin, 70)
        XCTAssertEqual(merged[0].lightMin, 180)
        XCTAssertEqual(merged[0].efficiency, 0.85)
        // Non-sleep fields: import still wins.
        XCTAssertEqual(merged[0].recovery, 80)
        XCTAssertEqual(merged[0].strain, 9.0)
    }

    /// A NON-edited day is unchanged: imports win for sleep too (the regression guard for the default path).
    func testNonEditedDayImportWinsSleep() {
        let imported = full(day: "2026-06-12", totalSleepMin: 480, deepMin: 90, remMin: 110,
                            lightMin: 280, efficiency: 0.92, recovery: 80, strain: 9.0)
        let computed = full(day: "2026-06-12", totalSleepMin: 300, deepMin: 50, remMin: 70,
                            lightMin: 180, efficiency: 0.85, recovery: 55, strain: 14.0)

        let merged = Repository.mergeDaily(imported: [imported], computed: [computed])  // no edited days

        XCTAssertEqual(merged[0].totalSleepMin, 480)
        XCTAssertEqual(merged[0].deepMin, 90)
        XCTAssertEqual(merged[0].efficiency, 0.92)
    }

    /// Only the edited day flips; other imported days keep import-wins precedence.
    func testOnlyFlaggedDayFlips() {
        let imp1 = full(day: "2026-06-11", totalSleepMin: 500, deepMin: 100, remMin: 120,
                        lightMin: 280, efficiency: 0.9, recovery: 70, strain: 8.0)
        let imp2 = full(day: "2026-06-12", totalSleepMin: 480, deepMin: 90, remMin: 110,
                        lightMin: 280, efficiency: 0.92, recovery: 80, strain: 9.0)
        let cmp1 = full(day: "2026-06-11", totalSleepMin: 250, deepMin: 40, remMin: 60,
                        lightMin: 150, efficiency: 0.8, recovery: 50, strain: 12.0)
        let cmp2 = full(day: "2026-06-12", totalSleepMin: 300, deepMin: 50, remMin: 70,
                        lightMin: 180, efficiency: 0.85, recovery: 55, strain: 14.0)

        let merged = Repository.mergeDaily(imported: [imp1, imp2], computed: [cmp1, cmp2],
                                           userEditedDays: ["2026-06-12"])
        let byDay = Dictionary(uniqueKeysWithValues: merged.map { ($0.day, $0) })
        // 06-11 not edited → import sleep wins.
        XCTAssertEqual(byDay["2026-06-11"]?.totalSleepMin, 500)
        // 06-12 edited → computed sleep wins.
        XCTAssertEqual(byDay["2026-06-12"]?.totalSleepMin, 300)
    }

    /// `userEditedDays` is derived from the LOCAL wake-day of every `userEdited` computed session.
    func testUserEditedDaysKeyedByLocalWakeDay() {
        let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 1_780_000_000))
        let endTs = 1_780_000_000
        let edited = CachedSleepSession(startTs: endTs - 8 * 3_600, endTs: endTs, efficiency: 0.85,
                                        restingHr: 52, avgHrv: 70, stagesJSON: "[]", userEdited: true)
        let plain = CachedSleepSession(startTs: endTs - 30 * 3_600, endTs: endTs - 22 * 3_600,
                                       efficiency: 0.9, restingHr: 50, avgHrv: 72, stagesJSON: "[]",
                                       userEdited: false)
        let days = Repository.userEditedDays([edited, plain])
        let expectedDay = AnalyticsEngine.dayString(endTs, offsetSec: offsetSec)
        XCTAssertEqual(days, [expectedDay])
    }

    /// A historical import has no raw streams, so editing its cached sleep must still rebuild the daily
    /// duration. Otherwise the debt ledger continues to read the original import's total after the edit.
    func testEditedImportedSleepRebuildsDailySleepFields() {
        let endTs = 1_780_000_000
        let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(endTs)))
        let day = AnalyticsEngine.dayString(endTs, offsetSec: offsetSec)
        let imported = full(day: day, totalSleepMin: 480, deepMin: 90, remMin: 110,
                            lightMin: 280, efficiency: 0.92, recovery: 80, strain: 9.0)
        let corrected = CachedSleepSession(
            startTs: endTs - 360 * 60,
            endTs: endTs,
            efficiency: 0.85,
            restingHr: 52,
            avgHrv: 70,
            stagesJSON: #"{"awake":20,"light":150,"deep":60,"rem":70}"#,
            userEdited: true
        )

        let rebuilt = Repository.applyingEditedSleepSessions([corrected], to: [imported])

        XCTAssertEqual(rebuilt[0].totalSleepMin, 280)
        XCTAssertEqual(rebuilt[0].deepMin, 60)
        XCTAssertEqual(rebuilt[0].remMin, 70)
        XCTAssertEqual(rebuilt[0].lightMin, 150)
        XCTAssertEqual(try XCTUnwrap(rebuilt[0].efficiency), 280.0 / 300.0, accuracy: 0.0001)
        XCTAssertEqual(rebuilt[0].recovery, 80, "non-sleep import fields must remain intact")
    }

    // MARK: - sleep_performance daily-column derivation (#614)
    //
    // The resolver derives the Rest composite from a banked DailyMetric's sleep totals when no
    // metricSeries point covers the day (a Bluetooth-only / just-synced selected day). Without it the
    // selected day resolved to nothing and Today borrowed the latest historical Rest. Mirrors Android
    // EditMergePrecedenceTest.

    /// A banked night with sleep totals derives the SAME Rest the persisted sleep_performance series
    /// carries (single source of truth: `AnalyticsEngine.Rest.composite(daily:)`).
    func testSleepPerformanceDailyColumnDerivesRestFromTotals() {
        let d = full(day: "2026-06-12", totalSleepMin: 480, deepMin: 90, remMin: 110,
                     lightMin: 280, efficiency: 0.92, recovery: 80, strain: 9.0)
        // Matches IntelligenceEngine's persisted sleep_performance projection (same composite).
        let expected = AnalyticsEngine.Rest.composite(daily: d)
        XCTAssertNotNil(expected)
        XCTAssertEqual(Repository.dailyColumn(key: "sleep_performance", day: d), expected)
    }

    /// No banked night (totalSleepMin nil) → no Rest to derive; the resolver leaves the day empty
    /// rather than fabricating a score.
    func testSleepPerformanceDailyColumnNilWhenNoSleep() {
        let d = DailyMetric(day: "2026-06-12", totalSleepMin: nil, efficiency: nil, deepMin: nil,
                            remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                            recovery: 60, strain: nil, exerciseCount: nil)
        XCTAssertNil(Repository.dailyColumn(key: "sleep_performance", day: d))
    }

    private func full(day: String, totalSleepMin: Double, deepMin: Double, remMin: Double,
                      lightMin: Double, efficiency: Double, recovery: Double, strain: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: recovery, strain: strain, exerciseCount: nil)
    }
}
