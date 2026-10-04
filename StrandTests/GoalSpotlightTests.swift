import XCTest
import WhoopStore
@testable import Strand

/// The rule every small goal surface shares (plan §17f/§17g): rings, counted daily goals, rows.
final class GoalSpotlightTests: XCTestCase {

    private func occurrence(_ requirement: GoalAction.Requirement, measured: Double?, done: Bool = false,
                            ring: Bool? = nil, created: TimeInterval = 0) -> GoalActionOccurrence {
        let action = GoalAction(title: "Goal", requirement: requirement, goalIds: [],
                                createdAt: Date(timeIntervalSince1970: created), showsAsRing: ring)
        return GoalActionOccurrence(action: action, day: "2026-10-04", isCompleted: done, isAutomatic: done,
                                    measured: measured)
    }

    func testAtMostThreeRingsAndEverythingElseIsCounted() {
        let today = [
            occurrence(.sleep(minimumHours: 7.5), measured: 6),
            occurrence(.steps(minimum: 10_000), measured: 7_000),
            occurrence(.activeCalories(minimum: 500), measured: 500, done: true),
            occurrence(.workout(sports: [], minimumMinutes: 30), measured: 10),
            occurrence(.manual, measured: nil),
            occurrence(.workout(sports: [], minimumMinutes: nil), measured: nil, done: true),
        ]
        let spot = GoalSpotlight.make(todayActions: today, periodSnapshots: [], longTerm: [], pinnedLongTerm: [])
        XCTAssertEqual(spot.rings.count, 3)
        // Fixed order: steps, active calories, sleep.
        XCTAssertEqual(spot.rings.map(\.action.requirement), [.steps(minimum: 10_000), .activeCalories(minimum: 500),
                                                              .sleep(minimumHours: 7.5)])
        XCTAssertEqual(spot.checks.count, 3)
        XCTAssertEqual(spot.dailyTotal, 6)
        XCTAssertEqual(spot.dailyDone, 2)
    }

    func testAGoalMarkedForARingWinsItsPlaceAndOneSwitchedOffStaysCounted() {
        let today = [
            occurrence(.steps(minimum: 10_000), measured: 7_000, ring: false),
            occurrence(.activeCalories(minimum: 500), measured: 100),
            occurrence(.sleep(minimumHours: 7.5), measured: 6),
            occurrence(.workout(sports: [], minimumMinutes: 30), measured: 10, ring: true),
        ]
        let spot = GoalSpotlight.make(todayActions: today, periodSnapshots: [], longTerm: [], pinnedLongTerm: [])
        XCTAssertFalse(spot.rings.contains { $0.action.requirement == .steps(minimum: 10_000) })
        XCTAssertTrue(spot.rings.contains { $0.action.requirement == .workout(sports: [], minimumMinutes: 30) })
        XCTAssertEqual(spot.checks.map(\.action.requirement), [.steps(minimum: 10_000)])
    }

    /// A workout goal with a minimum length fills up by its longest matching workout, the same rule
    /// that ticks it off, so a full ring and a ticked goal agree.
    func testWorkoutMinutesFollowTheLongestMatchingWorkout() {
        func row(_ minutes: Double, _ sport: String) -> WorkoutRow {
            WorkoutRow(startTs: 0, endTs: Int(minutes * 60), sport: sport, source: "whoop", durationS: minutes * 60,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                       notes: nil, steps: nil)
        }
        let requirement = GoalAction.Requirement.workout(sports: ["Running"], minimumMinutes: 30)
        let measured = GoalActionEvaluator.measuredValue(requirement, metric: nil, activeKcal: nil,
                                                         workouts: [row(20, "Running"), row(25, "Running"), row(60, "Cycling")])
        XCTAssertEqual(measured, 25)
        XCTAssertFalse(GoalActionEvaluator.automaticCompletion(requirement, metric: nil,
                                                               workouts: [row(20, "Running"), row(25, "Running")]))
        XCTAssertNil(GoalActionEvaluator.measuredValue(.workout(sports: [], minimumMinutes: nil), metric: nil,
                                                       activeKcal: nil, workouts: [row(40, "Running")]))
    }
}
