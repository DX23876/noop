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
        XCTAssertEqual(reloaded.goal(id: goal.id)?.closure?.kind, .achieved)
        XCTAssertNotNil(reloaded.goal(id: goal.id)?.closure?.date)
    }

    func testPauseAndResumeKeepAMachineReadableInterval() {
        let store = freshStore()
        let goal = activeGoal()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3 * 86_400)
        store.goals = [goal]

        store.pause(goal.id, reason: .travel, on: start)
        XCTAssertEqual(store.goal(id: goal.id)?.status, .paused)
        XCTAssertEqual(store.goal(id: goal.id)?.pauseIntervals.last?.reason, .travel)
        XCTAssertNil(store.goal(id: goal.id)?.pauseIntervals.last?.endedAt)

        store.resume(goal.id, on: end)
        XCTAssertEqual(store.goal(id: goal.id)?.status, .active)
        XCTAssertEqual(store.goal(id: goal.id)?.pauseIntervals.last?.endedAt, end)
    }

    func testClosingPausedGoalClosesOpenPauseToo() {
        let store = freshStore()
        let goal = activeGoal()
        let pausedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let achievedAt = pausedAt.addingTimeInterval(86_400)
        store.goals = [goal]
        store.pause(goal.id, reason: .illness, on: pausedAt)

        store.markAchieved(goal.id, on: achievedAt)

        XCTAssertEqual(store.goal(id: goal.id)?.pauseIntervals.last?.endedAt, achievedAt)
        XCTAssertEqual(store.goal(id: goal.id)?.closure?.date, achievedAt)
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

    /// The proactive repeat-guards are keyed on the goal's TARGET DATE, so moving that date re-arms
    /// them without anyone clearing anything — but a DELETED goal can never be reached again, so its
    /// keys would sit in UserDefaults for the life of the install.
    func testRemovingAGoalClearsItsNudgeStamps() {
        let suite = "goal-stamps-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let store = CoachGoalStore(defaults: d)
        let goal = CoachGoal(kind: .run, title: "10k", targetDate: Date().addingTimeInterval(-86_400))
        store.goals = [goal]

        let review = CoachGoalNudgeStamps.reviewKey(goalId: goal.id)
        let deadline = CoachGoalNudgeStamps.deadlineKey(goalId: goal.id, important: true)
        CoachGoalNudgeStamps.stamp(review, for: goal, defaults: d)
        CoachGoalNudgeStamps.stamp(deadline, for: goal, defaults: d)
        XCTAssertNotNil(d.string(forKey: review))

        store.remove(goal.id)

        XCTAssertNil(d.string(forKey: review))
        XCTAssertNil(d.string(forKey: deadline))
    }

    /// The self-healing half: the same goal at a NEW target date has not been spoken about yet, which
    /// is what makes "extend the date" — the review's own closing offer — not buy permanent silence.
    func testMovingTheTargetDateReArmsTheGuard() {
        let suite = "goal-stamps-rearm-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        var goal = CoachGoal(kind: .run, title: "10k", targetDate: Date().addingTimeInterval(-86_400))
        let key = CoachGoalNudgeStamps.reviewKey(goalId: goal.id)

        CoachGoalNudgeStamps.stamp(key, for: goal, defaults: d)
        XCTAssertTrue(CoachGoalNudgeStamps.alreadyFired(key, for: goal, defaults: d))

        goal.targetDate = Date().addingTimeInterval(30 * 86_400)
        XCTAssertFalse(CoachGoalNudgeStamps.alreadyFired(key, for: goal, defaults: d),
                       "a moved deadline is a new moment, not one already spoken about")
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
