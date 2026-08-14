import XCTest
@testable import Strand

/// Guards the goal route's persistence rules — above all that suggesting it is IDEMPOTENT.
@MainActor
final class CoachGoalMilestoneRouteTests: XCTestCase {

    private func store() -> CoachGoalStore {
        // A private suite so these never touch the app's real goals.
        let defaults = UserDefaults(suiteName: "route-tests-\(UUID().uuidString)")!
        return CoachGoalStore(defaults: defaults)
    }

    private func weightGoal(created: TimeInterval = -60 * 86_400) -> CoachGoal {
        CoachGoal(kind: .weight, title: "Lighter", baseline: 100, target: 70,
                  targetDate: Date().addingTimeInterval(120 * 86_400),
                  createdAt: Date().addingTimeInterval(created))
    }

    /// The bug this exists for: the second call rebuilt every waypoint with a NEW UUID, so the
    /// "changed?" guard was always true — assign → didSet → @Published → re-render → refresh → repeat.
    /// On screen the Today goal tile churned itself out of existence when it was tapped.
    func testSuggestingTheRouteTwiceChangesNothing() {
        let s = store()
        s.goals = [weightGoal()]

        s.ensureMilestones()
        let first = s.goals[0].milestones
        XCTAssertFalse(first.isEmpty)

        s.ensureMilestones()
        XCTAssertEqual(s.goals[0].milestones, first,
                       "identical inputs must produce an identical route, identity included")

        s.ensureMilestones()
        XCTAssertEqual(s.goals[0].milestones, first, "and it must stay settled")
    }

    /// Identity has to survive too — a changed id is what made SwiftUI rebuild the rows.
    func testWaypointIdentityIsStableAcrossCalls() {
        let s = store()
        s.goals = [weightGoal()]
        s.ensureMilestones()
        let ids = s.goals[0].milestones.map(\.id)
        s.ensureMilestones()
        XCTAssertEqual(s.goals[0].milestones.map(\.id), ids)
    }

    /// An edited waypoint keeps its value AND its date; an untouched one follows a changed plan.
    func testCustomWaypointsSurviveAReSuggest() {
        let s = store()
        s.goals = [weightGoal()]
        s.ensureMilestones()
        let target = s.goals[0].milestones[1]
        let movedDate = target.expectedDate.addingTimeInterval(9 * 86_400)
        s.updateMilestone(goalId: s.goals[0].id, milestoneId: target.id,
                          value: 91, expectedDate: movedDate)

        s.ensureMilestones()
        let custom = s.goals[0].milestones.first { $0.isCustom }
        XCTAssertNotNil(custom, "the user's edit must survive")
        XCTAssertEqual(custom?.value, 91)
        XCTAssertEqual(custom?.expectedDate, movedDate, "a moved waypoint keeps its own date")
    }

    /// A reached waypoint keeps the date it was FIRST passed, even if the value wobbles back later.
    func testReachedWaypointsKeepTheirFirstDate() {
        let s = store()
        s.goals = [weightGoal()]
        s.ensureMilestones()
        let goalId = s.goals[0].id
        let firstPass = Date().addingTimeInterval(-3 * 86_400)

        s.markMilestonesReached(goalId: goalId, current: 94, on: firstPass)
        let reached = s.goals[0].milestones.filter { $0.achievedAt != nil }
        XCTAssertFalse(reached.isEmpty, "95 kg is passed at 94 kg on a downward goal")

        s.markMilestonesReached(goalId: goalId, current: 94, on: Date())
        XCTAssertEqual(s.goals[0].milestones.filter { $0.achievedAt != nil }.map(\.achievedAt),
                       reached.map(\.achievedAt), "already-reached waypoints are never re-stamped")

        s.ensureMilestones()
        XCTAssertEqual(s.goals[0].milestones.filter { $0.achievedAt != nil }.count, reached.count,
                       "a re-suggest must not erase what already happened")
    }

    /// Editing a goal must not cost it its route. `commit(editingId:)` rebuilds the goal to preserve
    /// its identity and history, and used to omit `milestones:` — taking the init default of `[]`. So
    /// every edit threw away both halves of what the route records: the dates waypoints were reached,
    /// and the waypoints the user had moved. `ensureMilestones` then rebuilt a fresh unreached route
    /// on the next refresh, which is precisely the erasure it documents itself as never doing.
    func testEditingAGoalKeepsItsRoute() {
        let s = store()
        s.goals = [weightGoal()]
        s.ensureMilestones()
        let goalId = s.goals[0].id

        // One waypoint the user moved, and one the measurement passed.
        let moved = s.goals[0].milestones[1]
        s.updateMilestone(goalId: goalId, milestoneId: moved.id,
                          value: 91, expectedDate: moved.expectedDate.addingTimeInterval(9 * 86_400))
        s.markMilestonesReached(goalId: goalId, current: 94, on: Date().addingTimeInterval(-3 * 86_400))
        let before = s.goals[0].milestones
        XCTAssertTrue(before.contains { $0.achievedAt != nil })
        XCTAssertTrue(before.contains { $0.isCustom })

        // The edit the one-page editor performs: same goal, a nudged motivation.
        var edited = s.goals[0]
        edited.motivation = "Knees"
        s.commit(edited, editingId: goalId)

        XCTAssertEqual(s.goals[0].milestones, before,
                       "an edit must carry the route through, identity and stamps included")
    }

    /// The route belongs to a pursuit, so it stops moving when the pursuit ends. Without a status
    /// guard a goal set aside months ago kept collecting `achievedAt` stamps from today's
    /// measurement — rewriting the record of something that had already finished.
    func testClosedGoalsAreNoLongerStamped() {
        let s = store()
        s.goals = [weightGoal()]
        s.ensureMilestones()
        let goalId = s.goals[0].id
        s.setAside(goalId, reason: "Injury")

        s.markMilestonesReached(goalId: goalId, current: 70, on: Date())

        XCTAssertTrue(s.goals[0].milestones.allSatisfy { $0.achievedAt == nil },
                      "a goal that was set aside cannot reach anything")
    }

    /// A paused goal is still being pursued, just not right now — it keeps being measured.
    func testPausedGoalsAreStillStamped() {
        let s = store()
        s.goals = [weightGoal()]
        s.ensureMilestones()
        let goalId = s.goals[0].id
        s.pause(goalId, reason: .pain)

        s.markMilestonesReached(goalId: goalId, current: 94, on: Date())

        XCTAssertTrue(s.goals[0].milestones.contains { $0.achievedAt != nil })
    }

    /// A goal with no target or no date has no route, and asking for one is a no-op rather than a crash.
    func testGoalWithoutAPlanGetsNoRoute() {
        let s = store()
        s.goals = [CoachGoal(kind: .custom, title: "Less screen time")]
        s.ensureMilestones()
        XCTAssertTrue(s.goals[0].milestones.isEmpty)
    }
}
