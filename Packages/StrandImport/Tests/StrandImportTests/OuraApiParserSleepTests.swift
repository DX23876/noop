import XCTest
@testable import StrandImport

final class OuraApiParserSleepTests: XCTestCase {
    func testParsesPeriodWithHypnogramAndFoldsDay() throws {
        let docs: [[String: Any]] = [[
            "id": "s1", "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "total_sleep_duration": 24000, "deep_sleep_duration": 6000,
            "light_sleep_duration": 12000, "rem_sleep_duration": 6000, "awake_time": 1200,
            "efficiency": 92, "average_heart_rate": 55, "lowest_heart_rate": 48,
            "average_hrv": 65, "average_breath": 14.2,
            "sleep_phase_5_min": "1234",
            "movement_30_sec": "1212",
            "heart_rate": ["interval": 300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 58, NSNull(), 57]]
        ]]
        let (periods, days) = OuraApiParser.parseSleep(docs)
        XCTAssertEqual(periods.count, 1)
        let p = try XCTUnwrap(periods.first)
        XCTAssertEqual(p.session.totalSleepMin, 400)              // 24000s ÷ 60
        XCTAssertEqual(p.session.lowestHr, 48)
        XCTAssertEqual(p.session.avgHrvMs, 65)
        XCTAssertEqual(p.session.stages.map(\.stage), ["deep", "light", "rem", "wake"])
        XCTAssertEqual(p.movement30s, [1, 2, 1, 2])
        XCTAssertEqual(p.hr.map(\.bpm), [60, 58, 57])            // null sample dropped
        // ts = bedtime_start epoch + i*interval, using the ORIGINAL items index (the null at i=2 is
        // skipped, so the 3rd kept sample is i=3, i.e. epoch + 900, not epoch + 600).
        let bedtimeStart = try XCTUnwrap(WhoopTime.parseISOWithOffset("2026-01-01T23:00:00+00:00"))
        let ts0 = Int(bedtimeStart.timeIntervalSince1970)
        XCTAssertEqual(p.hr.map(\.ts), [ts0, ts0 + 300, ts0 + 900])
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.day, "2026-01-02")
        XCTAssertEqual(days.first?.totalSleepMin, 400)
        XCTAssertEqual(days.first?.restingHr, 48)                // lowestHr ≈ resting fallback
        XCTAssertEqual(days.first?.respRateBpm, 14.2)            // average_breath folded onto the day rollup
    }

    func testSkipsPeriodWithInvalidSpan() {
        let (periods, _) = OuraApiParser.parseSleep([["bedtime_start": "nope", "bedtime_end": "nope"]])
        XCTAssertTrue(periods.isEmpty)
    }

    func testSampleSeriesSkipsFiniteButHugeValuesWithoutCrashing() throws {
        // Both `ts` and `bpm` in sampleSeries are Double->Int casts; a finite-but-huge value for EITHER
        // (a crafted `interval` or a crafted `items` element) must be skipped, never trap Int(...).

        // A huge `interval` blows the 2nd sample's ts (t0 + 1*interval) past Int range; the 1st sample's
        // ts (t0 + 0*interval == t0) stays in range and must still be kept.
        let hugeIntervalDocs: [[String: Any]] = [[
            "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "heart_rate": ["interval": 1e300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 58]]
        ]]
        let (hugeIntervalPeriods, _) = OuraApiParser.parseSleep(hugeIntervalDocs)
        let hugeIntervalPeriod = try XCTUnwrap(hugeIntervalPeriods.first)
        XCTAssertEqual(hugeIntervalPeriod.hr.map(\.bpm), [60])

        // A huge `items` element (bpm itself) must be skipped even with a perfectly normal interval/ts.
        let hugeItemDocs: [[String: Any]] = [[
            "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "heart_rate": ["interval": 300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 1e300, 58]]
        ]]
        let (hugeItemPeriods, _) = OuraApiParser.parseSleep(hugeItemDocs)
        let hugeItemPeriod = try XCTUnwrap(hugeItemPeriods.first)
        XCTAssertEqual(hugeItemPeriod.hr.map(\.bpm), [60, 58])
    }
}
