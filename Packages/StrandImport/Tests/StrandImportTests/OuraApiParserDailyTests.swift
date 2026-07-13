import XCTest
@testable import StrandImport

final class OuraApiParserDailyTests: XCTestCase {
    func testReadinessMapsSkinTempAndRefScoreButNotRhr() {
        let (days, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "score": 80, "temperature_deviation": -0.2,
            "contributors": ["resting_heart_rate": 50, "hrv_balance": 70]
        ]], endpoint: "daily_readiness")
        // contributors.resting_heart_rate is a 0-100 readiness SCORE, not bpm — must not land on restingHr.
        XCTAssertNil(days.first?.restingHr)
        XCTAssertEqual(days.first?.skinTempDevC, -0.2)
        XCTAssertEqual(days.first?.readinessScore, 80)
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "ref_readiness_score", value: 80)))
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "oura_readiness_hrv_balance", value: 70)))
    }

    /// Regression test: `contributors.resting_heart_rate` is a 0-100 readiness contributor SCORE, not bpm.
    /// A prior bug stored it directly as the user's resting HR (scores like 99/100/1/10/43 as "RHR" across
    /// ~493 imported days). It must stay nil here — the real resting HR comes from sleep's
    /// `lowest_heart_rate` (see `OuraApiParser.parseSleep`) — while the raw score still surfaces honestly
    /// as an extra under its own name.
    func testReadinessContributorRhrScoreDoesNotBecomeRestingHr() {
        let (days, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "score": 80,
            "contributors": ["resting_heart_rate": 99]
        ]], endpoint: "daily_readiness")
        XCTAssertNil(days.first?.restingHr)
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "oura_readiness_resting_heart_rate", value: 99)))
    }

    func testActivityMapsStepsAndScoreIsReferenceOnly() {
        let (days, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "score": 88, "steps": 9000,
            "active_calories": 500, "total_calories": 2400
        ]], endpoint: "daily_activity")
        XCTAssertEqual(days.first?.steps, 9000)
        XCTAssertEqual(days.first?.activeKcal, 500)
        // The activity SCORE is reference-only — never a dailyMetric score column.
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "ref_activity_score", value: 88)))
    }

    func testResilienceLevelEncodedReferenceOnly() {
        let (_, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "level": "solid", "contributors": ["sleep_recovery": 60.0]
        ]], endpoint: "daily_resilience")
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "ref_resilience_level", value: 3)))
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "oura_resilience_sleep_recovery", value: 60)))
    }

    func testSpo2MapsAverage() {
        let (days, _) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "spo2_percentage": ["average": 96.5]
        ]], endpoint: "daily_spo2")
        XCTAssertEqual(days.first?.spo2Pct, 96.5)
    }
}
