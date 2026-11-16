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

    /// The report this file is named after, in the shape it actually reaches people: every set ticked on
    /// the screen and "mark at least one set as done" on the finish (Discord, 2026-11-16; a tester on
    /// 2026-11-14 whose routine "finished once and then never again").
    ///
    /// A tick travels through `changeDraft`, which saves the draft and hands it back. When the save is
    /// refused, the screen still receives the ticked draft and draws it, while the store keeps the old
    /// one, and the finish reads the store. So the two can disagree, and nothing says so. A store that
    /// rejects writes is the honest way to produce it: on a phone it is a busy timeout under a long
    /// backfill write, or a full disk.
    func testATickTheStoreRefusedIsNotHandedBackAsSaved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sqlite").path
        let store = try await WhoopStore(path: path)
        let now = Int(Date().timeIntervalSince1970)
        let base = draft(completed: false, startedAt: now - 600)
        try await store.saveWorkoutDraft(base)

        let refusing = try WhoopStore.readOnly(path: path)
        let exercise = try XCTUnwrap(base.exercises.first)
        let set = try XCTUnwrap(exercise.sets.first)
        let answer = await CoreTraining.changeDraft(store: refusing, args: [
            "change": "set", "exercise": exercise.id.uuidString, "set": set.id.uuidString, "done": true])

        XCTAssertNil(answer, "a tick the store refused must not come back as a saved draft")

        // What the wearer meets next, and what the screen must never contradict.
        let kept = try await refusing.workoutDraft()
        XCTAssertEqual(kept?.exercises.first?.sets.first?.isCompleted, false,
                       "the store kept the untouched draft, which is why the finish refuses")
        let finish = await CoreTraining.finishDraft(store: refusing, sessionRPE: nil)
        XCTAssertEqual(finish.outcome, .noCompletedWork)
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
