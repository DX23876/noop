import Foundation
import XCTest
import StrandTraining
import WhoopStore
@testable import NoopCore

/// Why a workout did not save. Four different failures used to arrive as one `nil` and were all shown as
/// "mark at least one set as done", so a tester whose sets were all ticked could not finish his workout and
/// the message named the one thing that was not wrong (issues #43, #47).
@MainActor
final class CoreWorkoutFinishTests: XCTestCase {

    private func draft(completed: Bool, startedAt: Int) -> WorkoutDraft {
        var set = NativeWorkoutSet(index: 0, weightKg: 60, reps: 8)
        set.isCompleted = completed
        let exercise = NativeWorkoutExercise(exerciseId: "bench", sets: [set])
        return WorkoutDraft(title: "Session", startedAt: startedAt,
                            plannedDay: LogicalDay.key(Date()), exercises: [exercise])
    }

    func testNoDraftSaysSoRatherThanBlamingTheSets() async throws {
        let store = try await WhoopStore.inMemory()
        let result = await CoreTraining.finishDraft(store: store, sessionRPE: nil)
        XCTAssertNil(result.workout)
        XCTAssertEqual(result.outcome, .noDraft)
    }

    func testNothingTickedIsTheOneCaseTheOldMessageWasRightAbout() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Int(Date().timeIntervalSince1970)
        _ = try await store.saveWorkoutDraft(draft(completed: false, startedAt: now - 600))
        let result = await CoreTraining.finishDraft(store: store, sessionRPE: nil)
        XCTAssertEqual(result.outcome, .noCompletedWork)
    }

    func testATickedSetSaves() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Int(Date().timeIntervalSince1970)
        _ = try await store.saveWorkoutDraft(draft(completed: true, startedAt: now - 600))
        let result = await CoreTraining.finishDraft(store: store, sessionRPE: nil)
        XCTAssertEqual(result.outcome, .saved)
        XCTAssertNotNil(result.workout)
    }

    /// The device clock behind the workout's own start: the workout has no length, which is a clock
    /// problem and says so, instead of sending the wearer back to tick sets that are already ticked.
    func testAClockThatWentBackwardsIsNamed() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        _ = try await store.saveWorkoutDraft(draft(completed: true, startedAt: Int(now.timeIntervalSince1970) + 3_600))
        let result = await CoreTraining.finishDraft(store: store, sessionRPE: nil, now: now)
        XCTAssertNil(result.workout)
        XCTAssertEqual(result.outcome, .clockWentBackwards)
    }

    /// The bridge hands the host the reason, not just a yes/no.
    func testTheBridgeCarriesTheReason() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("finish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            ShadowSession.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(ShadowSession.start(path: dir.appendingPathComponent("core.sqlite").path,
                                           deviceId: "my-whoop"), 0)
        let settled = await CoreCall.run("training.finishDraft", "{}")
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(settled.utf8)) as? [String: Any])
        XCTAssertEqual(answer["saved"] as? Bool, false)
        XCTAssertEqual(answer["reason"] as? String, "noDraft")
    }
}
