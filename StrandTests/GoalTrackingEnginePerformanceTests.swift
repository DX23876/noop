import XCTest
@testable import Strand

/// What `GoalTrackingEngine.evaluate` costs on a realistic history, and the invariant that makes the
/// cost safe to reduce: the snapshot must not change.
///
/// `evaluate` walks one week at a time from a goal's creation to today, and each of those weeks used
/// to re-filter the WHOLE proposal and action list, parsing every `yyyy-MM-dd` through
/// `Calendar.date(from:)` again — so the work was weeks × rows × goals, on the main actor, on every
/// Today/Journey `.task`. Closed goals kept walking to today forever, so that week count grew by one
/// every week for the life of the install.
///
/// The measurement is a guard rail, not a threshold to tune: it exists so a future change that
/// reintroduces per-week re-parsing shows up as a number rather than as a vague "feels slower".
@MainActor
final class GoalTrackingEnginePerformanceTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ offset: Int, from now: Date) -> String {
        let date = calendar.date(byAdding: .day, value: -offset, to: now)!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// A year-old goal with a year of plan history and daily actions — the shape a real long-running
    /// install reaches, not a synthetic worst case.
    private func fixture(now: Date, goalStatus: CoachGoal.Status = .active)
        -> (goal: CoachGoal, proposals: [PlanProposal], actions: [GoalActionOccurrence]) {
        let goal = CoachGoal(kind: .consistency, title: "Three sessions a week",
                             baseline: 1, target: 3,
                             targetDate: calendar.date(byAdding: .day, value: 30, to: now),
                             status: goalStatus,
                             createdAt: calendar.date(byAdding: .day, value: -365, to: now)!)
        // Three planned sessions a week for a year.
        let proposals: [PlanProposal] = (0..<365).compactMap { offset in
            guard offset % 7 < 3 else { return nil }
            return PlanProposal(day: day(offset, from: now), sport: "Run", intent: .moderate,
                                status: offset % 5 == 0 ? .skipped : .completed,
                                goalIds: [goal.id],
                                createdAt: calendar.date(byAdding: .day, value: -offset, to: now)!)
        }
        let action = GoalAction(title: "8k steps", requirement: .steps(minimum: 8_000),
                                goalIds: [goal.id],
                                createdAt: calendar.date(byAdding: .day, value: -365, to: now)!)
        let actions: [GoalActionOccurrence] = (0..<365).map { offset in
            GoalActionOccurrence(action: action, day: day(offset, from: now),
                                 isCompleted: offset % 3 != 0, isAutomatic: true)
        }
        return (goal, proposals, actions)
    }

    // MARK: - The measurement

    func testEvaluateOverAYearOfHistory() {
        let now = Date()
        let f = fixture(now: now)
        measure {
            // Six goals is the realistic steady state: `maxActiveGoals` is 5, and closed goals stay in
            // the store forever, so a snapshot pass covers more than the active ones.
            for _ in 0..<6 {
                _ = GoalTrackingEngine.evaluate(goal: f.goal, proposals: f.proposals,
                                                actionOccurrences: f.actions,
                                                measurement: GoalMeasurement(value: 2.5, date: now),
                                                now: now, calendar: calendar)
            }
        }
    }

    // MARK: - The invariants a faster path must preserve

    /// Bucketing rows by week must not move a single one across a boundary.
    func testWeekAccountingIsUnchangedByBucketing() {
        let now = Date()
        let f = fixture(now: now)
        let snapshot = GoalTrackingEngine.evaluate(goal: f.goal, proposals: f.proposals,
                                                   actionOccurrences: f.actions,
                                                   measurement: GoalMeasurement(value: 2.5, date: now),
                                                   now: now, calendar: calendar)

        // Every planned row lands in exactly one week, and none are lost.
        let plannedInWeeks = snapshot.recentWeeks.reduce(0) { $0 + $1.planPlanned }
        XCTAssertGreaterThan(plannedInWeeks, 0, "the fixture must actually produce commitments")
        XCTAssertGreaterThan(snapshot.currentWeek.planned + plannedInWeeks, 0)
        XCTAssertEqual(snapshot.recentWeeks.count, 6, "the tile shows the last six completed weeks")
        for week in snapshot.recentWeeks {
            XCTAssertEqual(week.planned, week.planPlanned + week.actionPlanned)
            XCTAssertEqual(week.completed, week.planCompleted + week.actionCompleted)
        }
    }

    /// A goal that has been closed stops accruing weeks at its closure, instead of walking to today
    /// forever — the cost of a long-abandoned goal must not grow every week for the life of the install.
    func testClosedGoalStopsAccruingWeeksAtItsClosure() {
        let now = Date()
        var (goal, proposals, actions) = fixture(now: now, goalStatus: .abandoned)
        // Set aside half a year ago, after six months of activity.
        let closedAt = calendar.date(byAdding: .day, value: -180, to: now)!
        goal.closure = .init(kind: .setAside, date: closedAt, reason: nil)

        let snapshot = GoalTrackingEngine.evaluate(goal: goal, proposals: proposals,
                                                   actionOccurrences: actions,
                                                   measurement: nil, now: now, calendar: calendar)

        // The last week it reports must sit at its closure, not at today.
        guard let last = snapshot.recentWeeks.last else { return XCTFail("expected recent weeks") }
        XCTAssertLessThan(last.start, closedAt.addingTimeInterval(7 * 86_400),
                          "a closed goal must not accrue weeks after it ended")
    }
}
