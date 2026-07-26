import XCTest
@testable import Strand

final class CoachTrainingPreferencesTests: XCTestCase {
    private func proposal(day: String, sport: String = "Jogging", status: PlanProposal.Status) -> PlanProposal {
        PlanProposal(day: day, sport: sport, intent: .easy, status: status)
    }

    func testWeekendDeclinesBecomeACautiousHypothesis() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-07-04", status: .declined), // Saturday
            proposal(day: "2026-07-05", status: .declined), // Sunday
            proposal(day: "2026-07-11", status: .skipped)
        ], days: 30, now: Self.date("2026-07-12"))
        XCTAssertTrue(report.contains("Jogging at weekends: 3 of 3"))
        XCTAssertTrue(report.contains("HYPOTHESES"))
        XCTAssertTrue(report.contains("do not silently remove activities"))
    }

    func testTwoDeclinesDoNotInventAPreference() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-07-04", status: .declined),
            proposal(day: "2026-07-05", status: .declined)
        ], days: 30, now: Self.date("2026-07-12"))
        XCTAssertEqual(report, "Not enough local planning decisions to identify a training preference yet.")
    }

    func testMixedOutcomesDoNotCreateAFalsePattern() {
        let report = CoachTrainingPreferences.report(proposals: [
            proposal(day: "2026-07-04", status: .declined),
            proposal(day: "2026-07-05", status: .completed),
            proposal(day: "2026-07-11", status: .declined),
            proposal(day: "2026-07-12", status: .completed)
        ], days: 30, now: Self.date("2026-07-13"))
        XCTAssertEqual(report, "No repeated local training-preference pattern is strong enough to report yet.")
    }

    private static func date(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)!
    }
}
