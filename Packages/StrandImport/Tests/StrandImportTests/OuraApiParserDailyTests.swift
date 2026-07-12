import XCTest
@testable import StrandImport

final class OuraApiParserDailyTests: XCTestCase {
    func testReadinessMapsRhrSkinTempAndRefScore() {
        let (days, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "score": 80, "temperature_deviation": -0.2,
            "contributors": ["resting_heart_rate": 50, "hrv_balance": 70]
        ]], endpoint: "daily_readiness")
        XCTAssertEqual(days.first?.restingHr, 50)
        XCTAssertEqual(days.first?.skinTempDevC, -0.2)
        XCTAssertEqual(days.first?.readinessScore, 80)
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "ref_readiness_score", value: 80)))
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "oura_readiness_hrv_balance", value: 70)))
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
