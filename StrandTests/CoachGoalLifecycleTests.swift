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
        store.goal = activeGoal()

        store.markAchieved()

        XCTAssertEqual(store.goal?.status, .achieved)
        XCTAssertEqual(store.goal?.history.last?.what, "Goal achieved")
    }

    func testSetAsideRecordsTheReasonInTheStory() {
        let store = freshStore()
        store.goal = activeGoal()

        store.setAside(reason: "injury or health")

        XCTAssertEqual(store.goal?.status, .abandoned)
        XCTAssertEqual(store.goal?.history.last?.what, "Goal set aside — injury or health")
    }

    func testSetAsideWithoutReasonStaysClean() {
        let store = freshStore()
        store.goal = activeGoal()

        store.setAside(reason: "   ")

        XCTAssertEqual(store.goal?.history.last?.what, "Goal set aside",
                       "an empty reason must not leave a dangling dash")
    }

    func testAClosedGoalCannotBeClosedAgain() {
        let store = freshStore()
        store.goal = activeGoal()
        store.markAchieved()
        let historyCount = store.goal?.history.count

        store.setAside(reason: "changed my mind")
        XCTAssertEqual(store.goal?.status, .achieved, "achieved is final until a new goal replaces it")
        XCTAssertEqual(store.goal?.history.count, historyCount, "no-op transitions must not spam the story")

        store.markAchieved()
        XCTAssertEqual(store.goal?.history.count, historyCount)
    }

    func testClosureSurvivesAStoreRoundTrip() {
        let suite = "goal-lifecycle-roundtrip-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let store = CoachGoalStore(defaults: d)
        store.goal = activeGoal()
        store.markAchieved()

        let reloaded = CoachGoalStore(defaults: d)
        XCTAssertEqual(reloaded.goal?.status, .achieved)
    }
}
