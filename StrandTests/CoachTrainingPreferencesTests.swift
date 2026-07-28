import XCTest
@testable import Strand

final class CoachTrainingPreferencesTests: XCTestCase {
    private func proposal(day: String,
                          sport: String = "Jogging",
                          status: PlanProposal.Status,
                          effect: PlanProposal.EffectFeedback? = nil) -> PlanProposal {
        PlanProposal(day: day, sport: sport, intent: .easy, status: status,
                     effectFeedback: effect)
    }

    func testWeekendDeclinesBecomeACautiousHypothesis() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-07-04", status: .declined), // Saturday
            proposal(day: "2026-07-05", status: .declined), // Sunday
            proposal(day: "2026-07-11", status: .skipped)
        ], days: 30, now: Self.date("2026-07-12"))
        XCTAssertTrue(report.contains("Jogging at weekends: 3 of 3"))
        XCTAssertTrue(report.contains("HYPOTHESES"))
        XCTAssertTrue(report.contains("do not establish causality"))
    }

    func testTwoDeclinesDoNotInventAPreference() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-07-04", status: .declined),
            proposal(day: "2026-07-05", status: .declined)
        ], days: 30, now: Self.date("2026-07-12"))
        XCTAssertTrue(report.contains("not enough recorded decisions"))
        XCTAssertTrue(report.contains("n=2"))
    }

    func testMixedOutcomesDoNotCreateAFalsePattern() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-07-04", status: .declined),
            proposal(day: "2026-07-05", status: .completed),
            proposal(day: "2026-07-11", status: .declined),
            proposal(day: "2026-07-12", status: .completed)
        ], days: 30, now: Self.date("2026-07-13"))
        XCTAssertTrue(report.contains("no repeated pattern is strong enough"))
        XCTAssertTrue(report.contains("missing feedback is not interpreted"))
    }

    func testEffectFeedbackIsSeparateFromCompletionAndMissing() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-07-01", sport: "Cycling", status: .completed, effect: .helpful),
            proposal(day: "2026-07-03", sport: "Cycling", status: .completed, effect: .helpful),
            proposal(day: "2026-07-05", sport: "Cycling", status: .completed, effect: .helpful),
            proposal(day: "2026-07-07", sport: "Cycling", status: .completed)
        ], days: 28, now: Self.date("2026-07-12"))

        XCTAssertTrue(report.contains("helpful after 3 of 3"))
        XCTAssertFalse(report.contains("3 of 4 completed recommendations"))
    }

    func testLongitudinalModelUsesFixedWindowsAndAllHistory() {
        let proposals = [
            proposal(day: "2025-01-04", status: .declined),
            proposal(day: "2025-01-05", status: .declined),
            proposal(day: "2025-01-11", status: .declined)
        ]
        let reports = CoachTrainingPreferences.longitudinalReports(
            proposals: proposals,
            now: Self.date("2026-07-12")
        )

        XCTAssertEqual(reports.map(\.identifier), ["28", "90", "365", "all"])
        XCTAssertFalse(reports[0].hasHypothesis)
        XCTAssertTrue(reports[3].hasHypothesis)
        XCTAssertTrue(reports[3].text.contains("all available history"))
    }

    func testExactWeekdayPatternIsVisibleOutsideWeekend() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-06-01", status: .declined), // Monday
            proposal(day: "2026-06-08", status: .declined),
            proposal(day: "2026-06-15", status: .skipped)
        ], days: 90, now: Self.date("2026-07-12"))

        XCTAssertTrue(report.contains("Jogging on Mondays: 3 of 3"))
    }

    func testSeasonalityAndHistoricalTrendAreExplicit() {
        let proposals = [
            proposal(day: "2025-12-06", status: .declined),
            proposal(day: "2026-01-10", status: .declined),
            proposal(day: "2026-02-07", status: .skipped)
        ]
        let report = CoachTrainingPreferences.longitudinalReport(
            proposals: proposals,
            now: Self.date("2026-07-12")
        )

        XCTAssertTrue(report.contains("Jogging in winter: 3 of 3"))
        XCTAssertTrue(report.contains("treat it as historical"))
    }

    private static func date(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)!
    }
}
