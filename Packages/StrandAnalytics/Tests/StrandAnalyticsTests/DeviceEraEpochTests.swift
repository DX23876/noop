import XCTest
@testable import StrandAnalytics

/// Boundary tests for `Baselines.deviceEraEpoch` (#459): the recalibration epoch at the latest
/// device-era boundary in a source-tagged nightly history, so a baseline never mixes two brands'
/// incompatible HRV scales (Oura RMSSD ~120-155 ms vs WHOOP ~72-112 ms across a switch). Mirrors the
/// Kotlin DeviceEraEpochTest so both platforms compute the SAME epoch for the same history.
final class DeviceEraEpochTests: XCTestCase {

    private func epochOfDayUTC(_ day: String) -> Double {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: day)!.timeIntervalSince1970
    }

    // MARK: single brand → no epoch

    func testEmptyHistoryIsZero() {
        XCTAssertEqual(Baselines.deviceEraEpoch([]), 0.0, accuracy: 0.0)
    }

    func testOneWhoopBrandAcrossManyIdsIsZero() {
        let days: [(day: String, sourceId: String)] = [
            (day: "2026-01-01", sourceId: "my-whoop"),
            (day: "2026-01-02", sourceId: "my-whoop-noop"),
            (day: "2026-01-03", sourceId: "whoop-EA:DC:0C:67:20:04"),
            (day: "2026-01-04", sourceId: "my-whoop"),
        ]
        XCTAssertEqual(Baselines.deviceEraEpoch(days), 0.0, accuracy: 0.0)
    }

    func testOneWearableBrandOnlyIsZero() {
        let days = (1...40).map { (day: String(format: "2026-01-%02d", $0), sourceId: "oura-import") }
        XCTAssertEqual(Baselines.deviceEraEpoch(days), 0.0, accuracy: 0.0)
    }

    // MARK: the reported case

    func testOuraThenWhoopReturnsFirstWhoopDay() {
        var days: [(day: String, sourceId: String)] = []
        for d in 1...15 { days.append((day: String(format: "2026-01-%02d", d), sourceId: "oura-import")) }
        for d in 16...31 { days.append((day: String(format: "2026-01-%02d", d), sourceId: "my-whoop")) }
        XCTAssertEqual(Baselines.deviceEraEpoch(days), epochOfDayUTC("2026-01-16"), accuracy: 0.0)
    }

    func testUnsortedInputIsSortedInternally() {
        let days: [(day: String, sourceId: String)] = [
            (day: "2026-01-16", sourceId: "my-whoop"),
            (day: "2026-01-02", sourceId: "oura-import"),
            (day: "2026-01-31", sourceId: "my-whoop"),
            (day: "2026-01-01", sourceId: "oura-import"),
            (day: "2026-01-20", sourceId: "my-whoop"),
        ]
        XCTAssertEqual(Baselines.deviceEraEpoch(days), epochOfDayUTC("2026-01-16"), accuracy: 0.0)
    }

    func testWhoopThenOuraReturnsFirstOuraDay() {
        var days: [(day: String, sourceId: String)] = []
        for d in 1...10 { days.append((day: String(format: "2026-02-%02d", d), sourceId: "my-whoop")) }
        for d in 11...20 { days.append((day: String(format: "2026-02-%02d", d), sourceId: "oura-import")) }
        XCTAssertEqual(Baselines.deviceEraEpoch(days), epochOfDayUTC("2026-02-11"), accuracy: 0.0)
    }

    func testOnlyTheLatestBoundaryMatters() {
        var days: [(day: String, sourceId: String)] = []
        for d in 1...5 { days.append((day: String(format: "2026-03-%02d", d), sourceId: "oura-import")) }
        for d in 6...10 { days.append((day: String(format: "2026-03-%02d", d), sourceId: "my-whoop")) }
        for d in 11...15 { days.append((day: String(format: "2026-03-%02d", d), sourceId: "oura-import")) }
        XCTAssertEqual(Baselines.deviceEraEpoch(days), epochOfDayUTC("2026-03-11"), accuracy: 0.0)
    }

    func testFitbitAndGarminAreDistinctBrands() {
        var days: [(day: String, sourceId: String)] = []
        for d in 1...5 { days.append((day: String(format: "2026-04-%02d", d), sourceId: "garmin-import")) }
        for d in 6...10 { days.append((day: String(format: "2026-04-%02d", d), sourceId: "fitbit-import")) }
        XCTAssertEqual(Baselines.deviceEraEpoch(days), epochOfDayUTC("2026-04-06"), accuracy: 0.0)
    }

    func testSameDayMixedBrandTieBreaksDeterministically() {
        // An overlap night carrying BOTH an Oura and a WHOOP row on the same day: the (day, sourceId)
        // total order must resolve the tie identically to the Kotlin twin, so the epoch never diverges by
        // platform. "my-whoop" < "oura-import" lexically, so on the last day the WHOOP row sorts last and
        // defines the current brand; the boundary lands where the last pure-Oura day gives way.
        let days: [(day: String, sourceId: String)] = [
            (day: "2026-06-01", sourceId: "oura-import"),
            (day: "2026-06-02", sourceId: "oura-import"),
            (day: "2026-06-03", sourceId: "my-whoop"),   // overlap day: both brands present
            (day: "2026-06-03", sourceId: "oura-import"),
            (day: "2026-06-04", sourceId: "my-whoop"),
        ]
        // After the (day, sourceId) total sort the overlap day orders my-whoop < oura-import, so the LAST
        // row on 2026-06-03 is oura-import; the current-brand (whoop) suffix walk breaks there and the era
        // opens at 2026-06-04 — the same result the Kotlin twin computes.
        XCTAssertEqual(Baselines.deviceEraEpoch(days), epochOfDayUTC("2026-06-04"), accuracy: 0.0)
    }

    // MARK: brand bucketing

    func testBrandBucketCollapsesWhoopIdsAndSeparatesWearables() {
        XCTAssertEqual(Baselines.brandBucket("my-whoop"), "whoop")
        XCTAssertEqual(Baselines.brandBucket("my-whoop-noop"), "whoop")
        XCTAssertEqual(Baselines.brandBucket("whoop-AA:BB:CC:DD:EE:FF"), "whoop")
        XCTAssertEqual(Baselines.brandBucket("apple-health"), "whoop")
        XCTAssertEqual(Baselines.brandBucket("oura-import"), "oura")
        XCTAssertEqual(Baselines.brandBucket("fitbit-import"), "fitbit")
        XCTAssertEqual(Baselines.brandBucket("garmin-import"), "garmin")
    }

    // MARK: the epoch actually re-seeds foldHistory across the scale jump

    func testEpochDropsPreSwitchNightsFromTheFold() {
        let values: [Double?] = Array(repeating: 135.0, count: 15) + Array(repeating: 90.0, count: 6)
        var dayKeys: [String] = []
        for d in 1...15 { dayKeys.append(String(format: "2026-05-%02d", d)) }
        for d in 16...21 { dayKeys.append(String(format: "2026-05-%02d", d)) }
        var sourceDays: [(day: String, sourceId: String)] = []
        for d in 1...15 { sourceDays.append((day: String(format: "2026-05-%02d", d), sourceId: "oura-import")) }
        for d in 16...21 { sourceDays.append((day: String(format: "2026-05-%02d", d), sourceId: "my-whoop")) }

        let eraEpoch = Baselines.deviceEraEpoch(sourceDays)
        let mixed = Baselines.foldHistory(values, dayKeys: dayKeys, cfg: Baselines.hrvCfg, baselineEpoch: 0.0)
        let gated = Baselines.foldHistory(values, dayKeys: dayKeys, cfg: Baselines.hrvCfg, baselineEpoch: eraEpoch)
        XCTAssertLessThan(gated.baseline, mixed.baseline,
                          "era-gated baseline sits near the WHOOP era, not the Oura-inflated mean")
        XCTAssertLessThanOrEqual(gated.baseline, 100.0, "era-gated baseline is close to the WHOOP nightly level")
        XCTAssertGreaterThan(Baselines.deviation(90.0, state: gated).z,
                             Baselines.deviation(90.0, state: mixed).z,
                             "z of a 90 ms WHOOP night is higher (less negative) against the era baseline")
    }
}
