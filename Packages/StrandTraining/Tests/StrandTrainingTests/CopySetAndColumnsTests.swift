import XCTest
@testable import StrandTraining

/// Two handles the logger was missing (issue #43): copying one set's numbers into the sets still to come,
/// and recording added weight on a movement the catalogue calls bodyweight.
final class CopySetAndColumnsTests: XCTestCase {

    private func set(_ index: Int, weight: Double?, reps: Int?, done: Bool = false,
                     phase: TrainingSetPhase = .work, parent: UUID? = nil) -> NativeWorkoutSet {
        var s = NativeWorkoutSet(index: index, phase: phase, weightKg: weight, reps: reps, parentSetId: parent)
        s.isCompleted = done
        return s
    }

    private func draft(_ sets: [NativeWorkoutSet]) -> WorkoutDraft {
        WorkoutDraft(title: "Session", startedAt: 1_000, plannedDay: "2026-11-14",
                     exercises: [NativeWorkoutExercise(exerciseId: "bench", sets: sets)])
    }

    func testTheNumbersReachTheSetsStillToCome() throws {
        var d = draft([set(0, weight: 80, reps: 8), set(1, weight: nil, reps: nil), set(2, weight: 20, reps: 3)])
        let first = d.exercises[0].sets[0].id
        let copied = try NativeWorkoutEngine.copySetToOpenSets(first, from: d.exercises[0].id, in: &d)
        XCTAssertEqual(copied, 2)
        XCTAssertEqual(d.exercises[0].sets.map(\.weightKg), [80, 80, 80])
        XCTAssertEqual(d.exercises[0].sets.map(\.reps), [8, 8, 8])
    }

    /// A ticked set is an account of what was lifted, so it is never rewritten.
    func testATickedSetKeepsWhatItRecorded() throws {
        var d = draft([set(0, weight: 80, reps: 8), set(1, weight: 60, reps: 12, done: true),
                       set(2, weight: nil, reps: nil)])
        let first = d.exercises[0].sets[0].id
        let copied = try NativeWorkoutEngine.copySetToOpenSets(first, from: d.exercises[0].id, in: &d)
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(d.exercises[0].sets[1].weightKg, 60, "a logged set is not a plan")
        XCTAssertEqual(d.exercises[0].sets[1].reps, 12)
        XCTAssertEqual(d.exercises[0].sets[2].weightKg, 80)
    }

    /// Earlier sets, warm-ups and cluster segments stay out of it.
    func testOnlyLaterWorkingSetsOfTheSameKindAreTouched() throws {
        let warmup = set(0, weight: 20, reps: 10, phase: .warmup)
        var d = draft([warmup, set(1, weight: 80, reps: 8),
                       set(2, weight: nil, reps: nil, phase: .warmup),
                       set(3, weight: nil, reps: nil, parent: warmup.id),
                       set(4, weight: nil, reps: nil)])
        let working = d.exercises[0].sets[1].id
        let copied = try NativeWorkoutEngine.copySetToOpenSets(working, from: d.exercises[0].id, in: &d)
        XCTAssertEqual(copied, 1, "the later warm-up and the cluster segment are not working sets")
        XCTAssertNil(d.exercises[0].sets[2].weightKg)
        XCTAssertNil(d.exercises[0].sets[3].weightKg)
        XCTAssertEqual(d.exercises[0].sets[4].weightKg, 80)
        XCTAssertEqual(d.exercises[0].sets[0].weightKg, 20, "an earlier set is never reached")
    }

    func testCompletionAndEffortBelongToTheSetThatPerformedThem() throws {
        var source = set(0, weight: 80, reps: 8, done: true)
        source.effort = TrainingEffortRating(scale: .rpe, value: 9)
        var d = draft([source, set(1, weight: nil, reps: nil)])
        try NativeWorkoutEngine.copySetToOpenSets(d.exercises[0].sets[0].id, from: d.exercises[0].id, in: &d)
        XCTAssertFalse(d.exercises[0].sets[1].isCompleted)
        XCTAssertNil(d.exercises[0].sets[1].effort)
        XCTAssertEqual(d.exercises[0].sets[1].weightKg, 80)
    }

    func testAnUnknownSetOrExerciseChangesNothing() throws {
        var d = draft([set(0, weight: 80, reps: 8), set(1, weight: nil, reps: nil)])
        XCTAssertThrowsError(try NativeWorkoutEngine.copySetToOpenSets(UUID(), from: d.exercises[0].id, in: &d))
        XCTAssertThrowsError(try NativeWorkoutEngine.copySetToOpenSets(d.exercises[0].sets[0].id, from: UUID(), in: &d))
        XCTAssertNil(d.exercises[0].sets[1].weightKg)
    }

    // MARK: - Which columns a set records

    func testABodyweightMovementRecordsAddedWeightWhenItCarriesSome() {
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .bodyweightReps), [.reps])
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .bodyweightReps, semantics: .addedBodyweight),
                       [.weight, .reps])
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .bodyweightReps, semantics: .bodyweightOnly), [.reps])
    }

    func testAWeightedModeAlwaysRecordsItsLoad() {
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .weightReps), [.weight, .reps])
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .weightedBodyweight), [.weight, .reps])
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .weightReps, unilateral: true), [.weight, .left, .right])
    }

    func testTimeAndDistanceModesAreUntouchedByLoadSemantics() {
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .duration, semantics: .addedBodyweight), [.seconds])
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .distanceDuration), [.distance, .seconds])
        XCTAssertEqual(TrainingSetColumns.inputs(mode: .weightDuration), [.weight, .seconds])
    }
}
