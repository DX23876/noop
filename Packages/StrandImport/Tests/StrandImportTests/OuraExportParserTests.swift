import XCTest
@testable import StrandImport

/// Pins the account-export ("Export Data" file) lane's resting-HR semantics — the file-import twin of
/// `OuraApiParserDailyTests`. Oura's daily_readiness `contributors.resting_heart_rate` is a 0-100
/// readiness contributor SCORE, not bpm; the real resting HR comes only from a sleep period's
/// `lowest_heart_rate`.
final class OuraExportParserTests: XCTestCase {

    private func bytes(_ s: String) -> Data { s.data(using: .utf8)! }

    /// Regression test (twin of the API-lane fix): a prior bug stored the readiness contributor score
    /// directly as the user's resting HR. With no sleep period in the export, restingHr must stay nil —
    /// never the 0-100 score — while the readiness score itself stays reference-only.
    func testReadinessContributorRhrScoreDoesNotBecomeRestingHr() {
        let json = """
        { "daily_readiness": [ { "day": "2026-01-02", "score": 80,
            "contributors": { "resting_heart_rate": 99 } } ] }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertEqual(days.count, 1)
        XCTAssertNil(days.first?.restingHr)
        XCTAssertEqual(days.first?.readinessScore, 80)
    }

    /// A flat `resting_heart_rate` key on the readiness record is the same contributor score in a
    /// flattened shape — it must not land on restingHr either.
    func testFlatReadinessRestingHeartRateKeyDoesNotBecomeRestingHr() {
        let json = """
        { "daily_readiness": [ { "day": "2026-01-02", "score": 80, "resting_heart_rate": 97 } ] }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertNil(days.first?.restingHr)
        XCTAssertEqual(days.first?.readinessScore, 80)
    }

    /// Sleep's `lowest_heart_rate` is the sole resting-HR source. The old code let the readiness loop
    /// overwrite the sleep-derived 48 bpm with the contributor score (96 here) whenever both categories
    /// were present — regardless of file iteration order, since the overwrite didn't check for nil.
    func testSleepLowestHeartRateIsTheSoleRestingHrSource() {
        let json = """
        {
          "sleep": [
            { "day": "2026-01-02", "bedtime_start": "2026-01-01T23:00:00+00:00",
              "bedtime_end": "2026-01-02T06:30:00+00:00", "total_sleep_duration": 25200,
              "lowest_heart_rate": 48 } ],
          "daily_readiness": [
            { "day": "2026-01-02", "score": 80,
              "contributors": { "resting_heart_rate": 96 } } ]
        }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        let day = days.first { $0.day == "2026-01-02" }
        XCTAssertEqual(day?.restingHr, 48)
        XCTAssertEqual(day?.readinessScore, 80)
    }

    /// The `readiness` category alias (older API-shaped exports) runs through the same loop and must
    /// obey the same rule.
    func testReadinessAliasCategoryDoesNotWriteRestingHr() {
        let json = """
        { "readiness": [ { "day": "2026-01-03", "score": 74,
            "contributors": { "resting_heart_rate": 100 } } ] }
        """
        let (days, _) = OuraExportParser.parse(["export.json": bytes(json)])
        XCTAssertNil(days.first?.restingHr)
        XCTAssertEqual(days.first?.readinessScore, 74)
    }
}
