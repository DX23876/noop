import Foundation
import XCTest
import WhoopStore
@testable import NoopCore

@MainActor
final class CoreGoalStateTests: XCTestCase {
    func testCommittedImageSurvivesReopenAndDoesNotChangeHostDefaults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goal-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("goals.sqlite").path
        let store = try await WhoopStore(path: path)
        let host = GoalPreferences.standard
        try await CoreGoalState.change(store: store) { context in
            context.preferences.set(Data([0, 255]), forKey: "goals.future")
            context.periods.commit(PeriodGoal(metric: .workouts, period: .week, target: 3), today: "2026-10-27")
        }
        XCTAssertTrue(GoalPreferences.standard === host)
        let reopened = try await WhoopStore(path: path)
        let result = try await CoreGoalState.read(store: reopened) { context in
            (context.periods.goals.map(\.target), context.preferences.data(forKey: "goals.future"))
        }
        XCTAssertEqual(result.0, [3])
        XCTAssertEqual(result.1, Data([0, 255]))
    }

    func testThrownMultiStoreChangeLeavesPersistedAndHostStateUntouched() async throws {
        enum Rejected: Error { case draft }
        let store = try await WhoopStore.inMemory()
        try await CoreGoalState.change(store: store) { $0.preferences.set(3, forKey: "goals.limit") }
        let before = try await store.goalPreferenceState()
        let host = PeriodGoalStore.shared
        do {
            try await CoreGoalState.change(store: store) { context in
                context.periods.commit(PeriodGoal(metric: .workouts, period: .week, target: 3), today: "2026-10-27")
                context.corrections.set(goalId: UUID(), workoutKey: "test", counts: false)
                throw Rejected.draft
            }
            XCTFail("a rejected draft must throw")
        } catch Rejected.draft {}
        let after = try await store.goalPreferenceState()
        XCTAssertEqual(after, before)
        XCTAssertTrue(PeriodGoalStore.shared === host)
    }

    func testParentRemovalAndCorrectionCleanupUseTheSameImage() async throws {
        let store = try await WhoopStore.inMemory()
        let parent = CoachGoal(kind: .consistency, title: "Regular training")
        let period = PeriodGoal(metric: .workouts, period: .week, target: 3, parentGoalId: parent.id)
        try await CoreGoalState.change(store: store) { context in
            context.goals.commit(parent)
            context.periods.commit(period, today: "2026-10-27")
            context.corrections.set(goalId: period.id, workoutKey: "test", counts: false)
        }
        try await CoreGoalState.change(store: store) { context in
            context.goals.remove(parent.id)
            XCTAssertNil(context.periods.goal(id: period.id)?.parentGoalId)
            context.periods.remove(period.id)
        }
        let cleaned = try await CoreGoalState.read(store: store) { context in
            context.goals.goals.isEmpty && context.periods.goals.isEmpty && context.corrections.corrections.isEmpty
        }
        XCTAssertTrue(cleaned)
    }

    func testConcurrentWriterCannotOverwriteNewerUserInput() async throws {
        let store = try await WhoopStore.inMemory()
        let first = Data("first".utf8), second = Data("second".utf8)
        let created = try await store.commitGoalPreferenceState(expected: nil, replacement: first)
        XCTAssertTrue(created)
        let stale = try await store.commitGoalPreferenceState(expected: nil, replacement: second)
        XCTAssertFalse(stale)
        let retained = try await store.goalPreferenceState()
        XCTAssertEqual(retained, first)
        let changed = try await store.commitGoalPreferenceState(expected: first, replacement: second)
        XCTAssertTrue(changed)
    }
}
