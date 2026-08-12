import XCTest
@testable import Strand

/// A goal must be able to END. These pin the store's lifecycle transitions: closing is recorded in the
/// history (the story stays honest), closing is idempotent, and a closed goal never reopens by accident.
@MainActor
final class CoachGoalLifecycleTests: XCTestCase {

    private func freshStore() -> CoachGoalStore {
        let d = UserDefaults(suiteName: "goal-lifecycle-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "goal-lifecycle")
        return CoachGoalStore(defaults: d)
    }

    private func activeGoal() -> CoachGoal {
        CoachGoal(kind: .run, title: "5k without stopping", targetDate: Date().addingTimeInterval(-86400))
    }

    func testMarkAchievedClosesTheGoalAndLogsIt() {
        let store = freshStore()
        let goal = activeGoal()
        store.goals = [goal]

        store.markAchieved(goal.id)

        XCTAssertEqual(store.goal(id: goal.id)?.status, .achieved)
        XCTAssertEqual(store.goal(id: goal.id)?.history.last?.what, "Goal achieved")
    }

    func testSetAsideRecordsTheReasonInTheStory() {
        let store = freshStore()
        let goal = activeGoal()
        store.goals = [goal]

        store.setAside(goal.id, reason: "injury or health")

        XCTAssertEqual(store.goal(id: goal.id)?.status, .abandoned)
        XCTAssertEqual(store.goal(id: goal.id)?.history.last?.what, "Goal set aside — injury or health")
    }

    func testSetAsideWithoutReasonStaysClean() {
        let store = freshStore()
        let goal = activeGoal()
        store.goals = [goal]

        store.setAside(goal.id, reason: "   ")

        XCTAssertEqual(store.goal(id: goal.id)?.history.last?.what, "Goal set aside",
                       "an empty reason must not leave a dangling dash")
    }

    func testAClosedGoalCannotBeClosedAgain() {
        let store = freshStore()
        let goal = activeGoal()
        store.goals = [goal]
        store.markAchieved(goal.id)
        let historyCount = store.goal(id: goal.id)?.history.count

        store.setAside(goal.id, reason: "changed my mind")
        XCTAssertEqual(store.goal(id: goal.id)?.status, .achieved, "achieved is final until a new goal replaces it")
        XCTAssertEqual(store.goal(id: goal.id)?.history.count, historyCount, "no-op transitions must not spam the story")

        store.markAchieved(goal.id)
        XCTAssertEqual(store.goal(id: goal.id)?.history.count, historyCount)
    }

    func testClosureSurvivesAStoreRoundTrip() {
        let suite = "goal-lifecycle-roundtrip-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let store = CoachGoalStore(defaults: d)
        let goal = activeGoal()
        store.goals = [goal]
        store.markAchieved(goal.id)

        let reloaded = CoachGoalStore(defaults: d)
        XCTAssertEqual(reloaded.goal(id: goal.id)?.status, .achieved)
    }

    // MARK: - Multiple simultaneous goals (#R-multi-goal)

    func testTwoGoalsOfDifferentKindsStayIndependentlyActive() {
        let store = freshStore()
        let run = CoachGoal(kind: .run, title: "5k")
        let sleep = CoachGoal(kind: .sleep, title: "7.5h a night")
        store.goals = [run, sleep]

        store.markAchieved(run.id)

        XCTAssertEqual(store.goal(id: run.id)?.status, .achieved)
        XCTAssertEqual(store.goal(id: sleep.id)?.status, .active, "closing one goal must not touch the other")
    }

    func testCanAddRejectsASecondGoalOfAnAlreadyActiveKind() {
        let store = freshStore()
        let run = CoachGoal(kind: .run, title: "5k")
        store.goals = [run]

        XCTAssertEqual(store.canAdd(kind: .run), .kindAlreadyActive(existingId: run.id))
        XCTAssertNil(store.canAdd(kind: .sleep), "a different kind is never blocked by an unrelated active goal")
    }

    func testCanAddExcludesTheGoalBeingEditedOrReplaced() {
        let store = freshStore()
        let run = CoachGoal(kind: .run, title: "5k")
        store.goals = [run]

        XCTAssertNil(store.canAdd(kind: .run, replacing: run.id),
                     "editing/replacing a goal must not collide with its own kind")
    }

    func testCanAddRejectsA6thGoalOnceTheCeilingIsReached() {
        let store = freshStore()
        store.goals = [
            CoachGoal(kind: .run, title: "a"), CoachGoal(kind: .sleep, title: "b"),
            CoachGoal(kind: .consistency, title: "c"), CoachGoal(kind: .strength, title: "d"),
            CoachGoal(kind: .weight, title: "e"),
        ]
        XCTAssertEqual(store.activeGoals.count, CoachGoalStore.maxActiveGoals)
        XCTAssertEqual(store.canAdd(kind: .stress), .tooManyActive)
    }

    func testMarkAchievedSetAsideAndRemoveOnlyTouchTheTargetedGoal() {
        let store = freshStore()
        let a = CoachGoal(kind: .run, title: "a")
        let b = CoachGoal(kind: .sleep, title: "b")
        let c = CoachGoal(kind: .strength, title: "c")
        store.goals = [a, b, c]

        store.markAchieved(a.id)
        store.setAside(b.id, reason: "life got busy")
        store.remove(c.id)

        XCTAssertEqual(store.goal(id: a.id)?.status, .achieved)
        XCTAssertEqual(store.goal(id: b.id)?.status, .abandoned)
        XCTAssertNil(store.goal(id: c.id), "remove deletes the goal entirely, unlike setAside")
    }

    // MARK: - Which goal leads

    /// The Today card and the iOS goal widget both show ONE goal, and they must show the SAME one — so
    /// the rule lives on the store rather than in each surface.
    func testPrimaryActiveGoalIsTheNearestTargetDate() {
        let store = freshStore()
        let far = CoachGoal(kind: .run, title: "Far", targetDate: Date().addingTimeInterval(90 * 86400))
        let near = CoachGoal(kind: .sleep, title: "Near", targetDate: Date().addingTimeInterval(7 * 86400))
        let undated = CoachGoal(kind: .custom, title: "Undated")
        store.goals = [far, undated, near]

        XCTAssertEqual(store.primaryActiveGoal?.title, "Near")
    }

    /// A goal with no date has no clock on it, so it never outranks one that has.
    func testUndatedGoalsSortLastAndThenByRecency() {
        let store = freshStore()
        let older = CoachGoal(kind: .stress, title: "Older",
                              createdAt: Date().addingTimeInterval(-10 * 86400))
        let newer = CoachGoal(kind: .custom, title: "Newer", createdAt: Date())
        store.goals = [older, newer]
        XCTAssertEqual(store.primaryActiveGoal?.title, "Newer")

        let dated = CoachGoal(kind: .run, title: "Dated",
                              targetDate: Date().addingTimeInterval(365 * 86400))
        store.goals = [older, newer, dated]
        XCTAssertEqual(store.primaryActiveGoal?.title, "Dated",
                       "a date, however distant, outranks no date at all")
    }

    /// Closed goals are history: nothing to lead with once they're all closed.
    func testPrimaryActiveGoalIgnoresClosedGoals() {
        let store = freshStore()
        let goal = activeGoal()
        store.goals = [goal]
        store.markAchieved(goal.id)

        XCTAssertNil(store.primaryActiveGoal)
    }

    func testSingularLegacyGoalMigratesIntoTheArrayAsOneElement() {
        let suite = "goal-lifecycle-migrate-singular-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let legacy = CoachGoal(kind: .run, title: "Legacy single goal")
        d.set(try! JSONEncoder().encode(legacy), forKey: "ai.goal")

        let store = CoachGoalStore(defaults: d)
        XCTAssertEqual(store.goals.count, 1)
        XCTAssertEqual(store.goals.first?.title, "Legacy single goal")
    }
}
