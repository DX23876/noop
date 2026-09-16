import XCTest
import StrandTraining
@testable import Strand

final class StrengthSessionHighlightsTests: XCTestCase {
    private var bench: TrainingExercise {
        TrainingStarterCatalog.exercises.first { $0.id == "noop:barbell-bench-press" }!
    }
    private var plank: TrainingExercise {
        TrainingStarterCatalog.exercises.first { $0.id == "noop:plank" }!
    }

    func testABetterSessionReportsBothRecordsAndTheChangeAgainstTheLastOne() throws {
        let previous = try workout(start: 1_000, weight: 80, reps: 5)
        let current = try workout(start: 200_000, weight: 90, reps: 5)
        let history = TrainingPerformanceHistory(native: [previous, current], resolved: empty,
                                                 exercises: [bench])

        let highlights = StrengthSessionHighlights.make(workout: current, exercises: [bench.id: bench],
                                                        history: history)

        XCTAssertEqual(Set(highlights.records.map(\.kind)), [.estimatedOneRepMax, .heaviestSet])
        let heaviest = try XCTUnwrap(highlights.records.first { $0.kind == .heaviestSet })
        XCTAssertEqual(heaviest.valueKg, 90)
        XCTAssertEqual(heaviest.previousKg, 80)
        let change = try XCTUnwrap(highlights.changes.first)
        XCTAssertEqual(change.deltaKg, 10)
        XCTAssertNil(change.deltaReps)
        XCTAssertEqual(change.previousTs, 1_000)
    }

    func testAFirstSessionIsNeitherARecordNorAChange() throws {
        let first = try workout(start: 1_000, weight: 80, reps: 5)
        let history = TrainingPerformanceHistory(native: [first], resolved: empty, exercises: [bench])

        let highlights = StrengthSessionHighlights.make(workout: first, exercises: [bench.id: bench],
                                                        history: history)

        XCTAssertTrue(highlights.isEmpty)
    }

    func testALighterSessionKeepsTheRecordAndStillReportsTheChange() throws {
        let previous = try workout(start: 1_000, weight: 90, reps: 5)
        let current = try workout(start: 200_000, weight: 80, reps: 8)
        let history = TrainingPerformanceHistory(native: [previous, current], resolved: empty,
                                                 exercises: [bench])

        let highlights = StrengthSessionHighlights.make(workout: current, exercises: [bench.id: bench],
                                                        history: history)

        XCTAssertTrue(highlights.records.isEmpty)
        let change = try XCTUnwrap(highlights.changes.first)
        XCTAssertEqual(change.deltaKg, -10)
        XCTAssertEqual(change.deltaReps, 3)
    }

    func testTimedWorkNeverProducesAWeightRecord() throws {
        let previous = try timedWorkout(start: 1_000, seconds: 45)
        let current = try timedWorkout(start: 200_000, seconds: 60)
        let history = TrainingPerformanceHistory(native: [previous, current], resolved: empty,
                                                 exercises: [plank])

        let highlights = StrengthSessionHighlights.make(workout: current, exercises: [plank.id: plank],
                                                        history: history)

        XCTAssertTrue(highlights.records.isEmpty)
    }

    private var empty: ResolvedStrengthHistory {
        .init(sessions: [], workouts: [], templates: [:])
    }

    private func workout(start: Int, weight: Double, reps: Int) throws -> NativeWorkout {
        var warmup = NativeWorkoutSet(index: 0, phase: .warmup, weightKg: weight - 40, reps: 10)
        warmup.isCompleted = true
        var work = NativeWorkoutSet(index: 1, weightKg: weight, reps: reps)
        work.isCompleted = true
        let draft = WorkoutDraft(title: "Push", startedAt: start, plannedDay: "1970-01-01",
                                 exercises: [.init(exerciseId: bench.id, sets: [warmup, work])])
        return try NativeWorkoutEngine.complete(draft: draft, endTs: start + 3_600)
    }

    private func timedWorkout(start: Int, seconds: Int) throws -> NativeWorkout {
        var set = NativeWorkoutSet(index: 0, durationS: seconds)
        set.isCompleted = true
        let draft = WorkoutDraft(title: "Core", startedAt: start, plannedDay: "1970-01-01",
                                 exercises: [.init(exerciseId: plank.id, sets: [set])])
        return try NativeWorkoutEngine.complete(draft: draft, endTs: start + 600)
    }
}
