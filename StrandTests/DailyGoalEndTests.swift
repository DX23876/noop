import XCTest
@testable import Strand

/// Daily goals that run until a date or only for today (plan §17e, Q25).
final class DailyGoalEndTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func date(_ value: String) -> Date {
        let p = value.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    func testAGoalIsDueUpToAndIncludingItsLastDay() {
        let action = GoalAction(title: "Steps", requirement: .steps(minimum: 10_000), goalIds: [],
                                createdAt: date("2026-10-01"), endsOn: "2026-10-03")
        XCTAssertTrue(GoalActionEvaluator.isDue(action, on: date("2026-10-03"), activeGoalIds: [], calendar: calendar))
        XCTAssertFalse(GoalActionEvaluator.isDue(action, on: date("2026-10-04"), activeGoalIds: [], calendar: calendar))
        XCTAssertFalse(action.hasEnded(today: "2026-10-03"))
        XCTAssertTrue(action.hasEnded(today: "2026-10-04"))
    }

    func testAGoalWithoutEndRunsOn() {
        let action = GoalAction(title: "Steps", requirement: .steps(minimum: 10_000), goalIds: [],
                                createdAt: date("2026-10-01"))
        XCTAssertTrue(GoalActionEvaluator.isDue(action, on: date("2027-10-01"), activeGoalIds: [], calendar: calendar))
        XCTAssertFalse(action.hasEnded(today: "2027-10-01"))
    }

    /// Goals and backups written before the end day existed decode unchanged and run without end.
    func testStoredGoalsWithoutAnEndDayStillDecode() throws {
        let old = GoalAction(title: "Walk", requirement: .manual, goalIds: [], createdAt: date("2026-01-01"))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "endsOn")
        let decoded = try JSONDecoder().decode(GoalAction.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.endsOn)
        XCTAssertEqual(decoded.title, "Walk")
    }

    /// A same-day Health count fills in when the strap has no step count for the day.
    func testStepsFallBackToTheSameDayHealthCount() {
        let action = GoalAction(title: "Steps", requirement: .steps(minimum: 8_000), goalIds: [],
                                createdAt: date("2026-10-01"))
        let occurrences = GoalActionEvaluator.occurrences(
            actions: [action], checkoffs: [], activeGoalIds: [], days: [], workouts: [],
            from: date("2026-10-02"), through: date("2026-10-02"),
            stepsByDay: ["2026-10-02": 9_100], calendar: calendar)
        XCTAssertEqual(occurrences.first?.isCompleted, true)
        XCTAssertEqual(occurrences.first?.measured, 9_100)
    }
}
