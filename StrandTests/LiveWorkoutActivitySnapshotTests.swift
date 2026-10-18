import XCTest
import StrandTraining
@testable import Strand

/// The Lock Screen counts elapsed time from an anchor the app computes once; pauses must be taken out and
/// a paused session must show frozen time.
final class LiveWorkoutActivitySnapshotTests: XCTestCase {
    private func snapshot(pausedAt: Date?, pausedSeconds: TimeInterval) -> LiveWorkoutActivitySnapshot {
        LiveWorkoutActivitySnapshot(kind: .cardio, title: "Walking",
                                    startedAt: Date(timeIntervalSince1970: 1_000),
                                    pausedAt: pausedAt, pausedSeconds: pausedSeconds, bpm: 110, zone: 2,
                                    distanceM: 1_200, paceSecPerKm: 600, setsDone: nil, setsTotal: nil,
                                    restEndsAt: nil)
    }

    func testTheElapsedAnchorShiftsByThePausedTime() {
        let running = snapshot(pausedAt: nil, pausedSeconds: 120)
        XCTAssertEqual(running.elapsedAnchor, Date(timeIntervalSince1970: 1_120))
        XCTAssertEqual(running.activeSeconds(at: Date(timeIntervalSince1970: 1_720)), 600)
    }

    func testAPausedSessionFreezesItsElapsedTime() {
        let paused = snapshot(pausedAt: Date(timeIntervalSince1970: 1_600), pausedSeconds: 100)
        XCTAssertEqual(paused.activeSeconds(at: Date(timeIntervalSince1970: 9_999)), 500)
    }

    func testNextStrengthSetFollowsTheSessionCursorAndItsActualValues() throws {
        let bench = NativeWorkoutExercise(exerciseId: "bench", sets: [
            NativeWorkoutSet(index: 0, weightKg: 60, reps: 8, isCompleted: true),
            NativeWorkoutSet(index: 1, weightKg: 62.5, reps: 6),
        ])
        let row = NativeWorkoutExercise(exerciseId: "row", sets: [
            NativeWorkoutSet(index: 0, weightKg: 40, reps: 10),
        ])
        var draft = WorkoutDraft(title: "Strength", startedAt: 1_000, plannedDay: "2026-10-18",
                                 exercises: [bench, row],
                                 cursor: ActiveExerciseCursor(exerciseId: bench.id))
        let titles = ["bench": "Bench press", "row": "Row"]
        let modes: [String: TrainingMeasurementMode] = ["bench": .weightReps, "row": .weightReps]

        let next = try XCTUnwrap(StrengthNextSet.resolve(in: draft, titles: titles, modes: modes,
                                                         unit: .kilograms))
        XCTAssertEqual(next.sessionId, draft.id)
        XCTAssertEqual(next.setId, bench.sets[1].id)
        XCTAssertEqual(next.exercise, "Bench press")
        XCTAssertEqual(next.number, 2)
        XCTAssertEqual(next.target, "\(TrainingPreferences.formattedWeight(62.5, unit: .kilograms)) × 6")
        XCTAssertTrue(next.canCompleteWithoutOpening)
        XCTAssertNotNil(StrengthNextSet.setToComplete(in: draft, sessionId: draft.id,
                                                      setId: next.setId, modes: modes))
        XCTAssertNil(StrengthNextSet.setToComplete(in: draft, sessionId: UUID(),
                                                   setId: next.setId, modes: modes))

        draft.exercises[0].sets[1].isCompleted = true
        XCTAssertNil(StrengthNextSet.setToComplete(in: draft, sessionId: draft.id,
                                                   setId: next.setId, modes: modes))
        XCTAssertEqual(StrengthNextSet.resolve(in: draft, titles: titles, modes: modes,
                                               unit: .kilograms)?.setId, row.sets[0].id)
    }

    func testAnUnseenSetCannotBeCompletedWithoutNumbersOrWhilePaused() throws {
        let empty = NativeWorkoutExercise(exerciseId: "bench", sets: [NativeWorkoutSet(index: 0, reps: 8)])
        var draft = WorkoutDraft(title: "Strength", startedAt: 1_000,
                                 plannedDay: "2026-10-18", exercises: [empty])
        let modes: [String: TrainingMeasurementMode] = ["bench": .weightReps]
        XCTAssertFalse(try XCTUnwrap(StrengthNextSet.resolve(in: draft, titles: [:], modes: modes,
                                                               unit: .kilograms)).canCompleteWithoutOpening)
        XCTAssertNil(StrengthNextSet.setToComplete(in: draft, sessionId: draft.id,
                                                   setId: empty.sets[0].id, modes: modes))
        draft.exercises[0].sets[0].weightKg = 60
        draft.state = .paused
        XCTAssertFalse(try XCTUnwrap(StrengthNextSet.resolve(in: draft, titles: [:], modes: modes,
                                                               unit: .kilograms)).canCompleteWithoutOpening)
    }

    func testRestControlOnlyAppliesToTheDisplayedTimer() {
        var draft = WorkoutDraft(title: "Strength", startedAt: 1_000,
                                 plannedDay: "2026-10-18")
        draft.timer = WorkoutTimerState(kind: .rest, startedAtTs: 1_100, endsAtTs: 1_220)
        XCTAssertTrue(StrengthRestAction.canApply(to: draft, sessionId: draft.id,
                                                   expectedEnd: 1_220, seconds: 15))
        XCTAssertFalse(StrengthRestAction.canApply(to: draft, sessionId: draft.id,
                                                    expectedEnd: 1_100, seconds: 0))
        XCTAssertFalse(StrengthRestAction.canApply(to: draft, sessionId: UUID(),
                                                    expectedEnd: 1_220, seconds: 0))
        draft.state = .paused
        XCTAssertFalse(StrengthRestAction.canApply(to: draft, sessionId: draft.id,
                                                    expectedEnd: 1_220, seconds: 0))
    }
}
