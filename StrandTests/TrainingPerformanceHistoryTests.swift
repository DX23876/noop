import XCTest
import StrandTraining
import WhoopStore
@testable import Strand

final class TrainingPerformanceHistoryTests: XCTestCase {
    private var bench: TrainingExercise {
        TrainingStarterCatalog.exercises.first { $0.id == "noop:barbell-bench-press" }!
    }

    func testImportedSessionOfTheSameReviewedLiftCountsAndTheNewestWins() throws {
        let anatomy = try XCTUnwrap(TrainingMuscleProjection.anatomy(for: bench))
        let native = try nativeWorkout(start: 1_000, weight: 80)
        let hevy = session(id: "hevy", start: 2_000, source: .hevyAPI, weight: 90, anatomy: anatomy)

        let history = TrainingPerformanceHistory(native: [native], resolved: resolved([hevy]),
                                                 exercises: [bench])

        XCTAssertEqual(history.entries(for: bench.id).map(\.startTs), [1_000, 2_000])
        let latest = try XCTUnwrap(history.latest(for: bench.id))
        XCTAssertFalse(latest.isNative)
        XCTAssertEqual(latest.workingSets.map(\.weightKg), [90])
        XCTAssertEqual(latest.workingSets.first?.effort?.scale, .rpe)
    }

    func testNativeProjectionAndUnmappedImportsNeverAddEntries() throws {
        let anatomy = try XCTUnwrap(TrainingMuscleProjection.anatomy(for: bench))
        let native = try nativeWorkout(start: 1_000, weight: 80)
        let projected = session(id: "noop-native", start: 1_000, source: .noopNative, weight: 80,
                                anatomy: anatomy)
        let unmapped = session(id: "unmapped", start: 3_000, source: .strong, weight: 200, anatomy: nil)

        let history = TrainingPerformanceHistory(native: [native], resolved: resolved([projected, unmapped]),
                                                 exercises: [bench])

        XCTAssertEqual(history.entries(for: bench.id).count, 1)
        XCTAssertEqual(history.latest(for: bench.id)?.isNative, true)
    }

    func testImportedPrefillFillsOnlyBlanksPositionByPosition() throws {
        let anatomy = try XCTUnwrap(TrainingMuscleProjection.anatomy(for: bench))
        let hevy = session(id: "hevy", start: 2_000, source: .hevyAPI, weight: 90, anatomy: anatomy)
        let history = TrainingPerformanceHistory(native: [], resolved: resolved([hevy]), exercises: [bench])
        var draft = WorkoutDraft(title: "Push", startedAt: 5_000, plannedDay: "1970-01-01", exercises: [
            .init(exerciseId: bench.id, sets: [.init(index: 0, phase: .warmup), .init(index: 1, weightKg: 100)])
        ])

        history.prefillImported(&draft)

        XCTAssertEqual(draft.exercises[0].sets[0].weightKg, 40)
        XCTAssertEqual(draft.exercises[0].sets[0].reps, 8)
        XCTAssertEqual(draft.exercises[0].sets[1].weightKg, 100)
        XCTAssertEqual(draft.exercises[0].sets[1].reps, 5)
    }

    func testRecordsSummariseEveryEligibleSessionAndRespectTheMeasurementMode() throws {
        let anatomy = try XCTUnwrap(TrainingMuscleProjection.anatomy(for: bench))
        let native = try nativeWorkout(start: 1_000, weight: 80)
        let hevy = session(id: "hevy", start: 2_000, source: .hevyAPI, weight: 90, anatomy: anatomy)
        let history = TrainingPerformanceHistory(native: [native], resolved: resolved([hevy]),
                                                 exercises: [bench])

        let records = history.records(for: bench.id, mode: .weightReps)
        XCTAssertEqual(records.sessionCount, 2)
        XCTAssertEqual(records.heaviestSetKg, 90)
        XCTAssertEqual(records.lastPerformedTs, 2_000)
        // 90 kg × 5 at RPE 8 corrects to 7 effective repetitions: 90 × (1 + 7/30).
        XCTAssertEqual(try XCTUnwrap(records.bestEstimatedOneRepMaxKg), 111, accuracy: 0.5)

        let timed = history.records(for: bench.id, mode: .duration)
        XCTAssertNil(timed.bestEstimatedOneRepMaxKg)
        XCTAssertNil(timed.heaviestSetKg)
        XCTAssertEqual(timed.sessionCount, 2)
    }

    private func nativeWorkout(start: Int, weight: Double) throws -> NativeWorkout {
        var set = NativeWorkoutSet(index: 0, weightKg: weight, reps: 5)
        set.isCompleted = true
        let draft = WorkoutDraft(title: "Push", startedAt: start, plannedDay: "1970-01-01",
                                 exercises: [.init(exerciseId: bench.id, sets: [set])])
        return try NativeWorkoutEngine.complete(draft: draft, endTs: start + 3_600)
    }

    private func session(id: String, start: Int, source: StrengthDataSource, weight: Double,
                         anatomy: ExerciseAnatomy?) -> ResolvedStrengthSession {
        let sets = [
            HevySet(index: 0, type: .warmup, weightKg: 40, reps: 8, distanceM: nil, durationS: nil,
                    rpe: nil, customMetric: nil),
            HevySet(index: 1, type: .normal, weightKg: weight, reps: 5, distanceM: nil, durationS: nil,
                    rpe: 8, customMetric: nil)
        ]
        let exercise = HevyExercise(index: 0, title: "Bench Press", templateId: "bench", supersetId: nil,
                                    notes: nil, sets: sets)
        let workout = HevyWorkout(id: id, title: "Push", routineId: nil, notes: nil, startTs: start,
                                  endTs: start + 3_600, updatedAtTs: start, createdAtTs: start,
                                  exercises: [exercise], source: source)
        return ResolvedStrengthSession(id: id, workout: workout,
                                       exercises: [.init(source: exercise, anatomy: anatomy)],
                                       canonicalRow: nil)
    }

    private func resolved(_ sessions: [ResolvedStrengthSession]) -> ResolvedStrengthHistory {
        .init(sessions: sessions, workouts: sessions.map(\.workout), templates: [:])
    }
}
