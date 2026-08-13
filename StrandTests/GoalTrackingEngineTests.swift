import XCTest
@testable import Strand

final class GoalTrackingEngineTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    private func date(_ value: String) -> Date {
        let p = value.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    private func proposal(_ day: String, goal: UUID, status: PlanProposal.Status,
                          reason: PlanProposal.SkipReason? = nil) -> PlanProposal {
        PlanProposal(day: day, sport: "Run", intent: .easy, status: status,
                     skipReason: reason, goalId: goal, decidedAt: date(day))
    }

    private func goal(created: String = "2026-03-01", status: CoachGoal.Status = .active,
                      pauses: [CoachGoal.PauseInterval] = []) -> CoachGoal {
        CoachGoal(kind: .custom, title: "Show up", status: status,
                  createdAt: date(created), pauseIntervals: pauses)
    }

    private func occurrence(_ day: String, goalIds: [UUID], completed: Bool) -> GoalActionOccurrence {
        let action = GoalAction(title: "Walk", requirement: .manual, goalIds: goalIds,
                                createdAt: date("2026-03-01"))
        return GoalActionOccurrence(action: action, day: day, isCompleted: completed,
                                    isAutomatic: false)
    }

    func testEightyPercentThresholdRoundsUp() {
        XCTAssertEqual(GoalTrackingEngine.requiredCompletions(for: 1), 1)
        XCTAssertEqual(GoalTrackingEngine.requiredCompletions(for: 2), 2)
        XCTAssertEqual(GoalTrackingEngine.requiredCompletions(for: 3), 3)
        XCTAssertEqual(GoalTrackingEngine.requiredCompletions(for: 5), 4)
    }

    func testFourOfFiveCompletesASuccessfulGoalWeek() {
        let g = goal()
        let rows = [2, 3, 4, 5].map { proposal("2026-03-0\($0)", goal: g.id, status: .completed) }
            + [proposal("2026-03-06", goal: g.id, status: .skipped, reason: .noTime)]
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: rows, measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertEqual(snapshot.recentWeeks.first(where: { $0.planned == 5 })?.state, .successful)
        XCTAssertEqual(snapshot.currentStreak, 1)
    }

    func testProtectedWeekNeitherExtendsNorBreaksSeries() {
        let g = goal()
        let rows = [
            proposal("2026-03-03", goal: g.id, status: .completed),
            proposal("2026-03-10", goal: g.id, status: .skipped, reason: .ill),
        ]
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: rows, measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertEqual(snapshot.recentWeeks.last(where: { $0.planned == 1 })?.state, .protected)
        XCTAssertEqual(snapshot.currentStreak, 1)
    }

    func testPauseIntervalProtectsIntersectingWeek() {
        let pause = CoachGoal.PauseInterval(startedAt: date("2026-03-10"),
                                            endedAt: date("2026-03-12"), reason: .travel)
        let g = goal(pauses: [pause])
        let rows = [proposal("2026-03-11", goal: g.id, status: .skipped, reason: .noTime)]
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: rows, measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertEqual(snapshot.recentWeeks.first(where: { $0.planned == 1 })?.state, .protected)
    }

    func testTwoOrdinaryFailedWeeksBecomeAtRisk() {
        let g = goal()
        let rows = [
            proposal("2026-03-03", goal: g.id, status: .skipped, reason: .noTime),
            proposal("2026-03-10", goal: g.id, status: .skipped, reason: .tired),
        ]
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: rows, measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertEqual(snapshot.health, .atRisk)
        XCTAssertEqual(snapshot.currentStreak, 0)
    }

    func testPastOpenCommitmentNeedsDecisionAndDoesNotBreakSeries() {
        let g = goal()
        let rows = [
            proposal("2026-03-03", goal: g.id, status: .completed),
            proposal("2026-03-10", goal: g.id, status: .accepted),
        ]
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: rows, measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertEqual(snapshot.health, .decisionNeeded)
        XCTAssertEqual(snapshot.currentStreak, 1)
    }

    func testNoCommitmentWeeksAreNeutral() {
        let snapshot = GoalTrackingEngine.evaluate(goal: goal(), proposals: [], measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertTrue(snapshot.recentWeeks.allSatisfy { $0.state == .neutral })
        XCTAssertEqual(snapshot.health, .building)
    }

    func testCurrentWeekThatCannotReachThresholdNeedsAttention() {
        let g = goal()
        let rows = (16...20).enumerated().map { offset, day in
            proposal("2026-03-\(day)", goal: g.id, status: offset < 2 ? .completed : .skipped,
                     reason: offset < 2 ? nil : .noTime)
        }
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: rows, measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertEqual(snapshot.currentWeek.planned, 5)
        XCTAssertEqual(snapshot.health, .attention)
    }

    func testDirectionAwareProgressForDecreasingGoal() {
        let g = CoachGoal(kind: .weight, title: "Weight", baseline: 80, target: 70,
                          targetDate: date("2026-06-01"), createdAt: date("2026-01-01"))
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: [],
                                                   measurement: .init(value: 75, date: date("2026-03-01")),
                                                   now: date("2026-03-01"), calendar: calendar)
        XCTAssertEqual(snapshot.progressFraction ?? -1, 0.5, accuracy: 0.0001)
    }

    func testMeasuredBehindTrendBecomesAtRisk() {
        let g = CoachGoal(kind: .run, title: "10k", baseline: 0, target: 10,
                          targetDate: date("2026-04-01"), createdAt: date("2026-01-01"))
        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: [],
                                                   measurement: .init(value: 2, date: date("2026-03-01")),
                                                   now: date("2026-03-01"), calendar: calendar)
        XCTAssertEqual(snapshot.trend.verdict, .behind)
        XCTAssertEqual(snapshot.health, .atRisk)
    }

    func testPausedGoalIsReportedAsPaused() {
        let snapshot = GoalTrackingEngine.evaluate(goal: goal(status: .paused), proposals: [], measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        XCTAssertEqual(snapshot.health, .paused)
    }

    func testPlanAndActionLanesMustEachReachEightyPercent() {
        let g = goal()
        let plans = [2, 3, 4, 5].map { proposal("2026-03-0\($0)", goal: g.id, status: .completed) }
            + [proposal("2026-03-06", goal: g.id, status: .skipped, reason: .noTime)]
        let actions = [2, 3, 4, 5, 6].enumerated().map { offset, day in
            occurrence("2026-03-0\(day)", goalIds: [g.id], completed: offset < 3)
        }

        let snapshot = GoalTrackingEngine.evaluate(goal: g, proposals: plans,
                                                   actionOccurrences: actions, measurement: nil,
                                                   now: date("2026-03-18"), calendar: calendar)
        let week = snapshot.recentWeeks.first { $0.planPlanned == 5 }

        XCTAssertEqual(week?.planCompleted, 4)
        XCTAssertEqual(week?.actionCompleted, 3)
        XCTAssertEqual(week?.state, .unsuccessful)
    }

    func testOneSharedOccurrenceCountsForEachExplicitGoal() {
        let first = goal(), second = goal()
        let shared = occurrence("2026-03-03", goalIds: [first.id, second.id], completed: true)

        let firstSnapshot = GoalTrackingEngine.evaluate(
            goal: first, proposals: [], actionOccurrences: [shared], measurement: nil,
            now: date("2026-03-18"), calendar: calendar)
        let secondSnapshot = GoalTrackingEngine.evaluate(
            goal: second, proposals: [], actionOccurrences: [shared], measurement: nil,
            now: date("2026-03-18"), calendar: calendar)

        XCTAssertEqual(firstSnapshot.recentWeeks.first { $0.actionPlanned == 1 }?.actionCompleted, 1)
        XCTAssertEqual(secondSnapshot.recentWeeks.first { $0.actionPlanned == 1 }?.actionCompleted, 1)
    }

    func testCompletedActionsDoNotMasqueradeAsOutcomeProgress() {
        let g = CoachGoal(kind: .weight, title: "Weight", baseline: 80, target: 70,
                          targetDate: date("2026-04-01"), createdAt: date("2026-01-01"))
        let completed = occurrence("2026-02-28", goalIds: [g.id], completed: true)

        let snapshot = GoalTrackingEngine.evaluate(
            goal: g, proposals: [], actionOccurrences: [completed],
            measurement: .init(value: 79, date: date("2026-03-01")),
            now: date("2026-03-01"), calendar: calendar)

        XCTAssertEqual(snapshot.progressFraction ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.trend.verdict, .behind)
        XCTAssertEqual(snapshot.health, .atRisk)
    }
}
