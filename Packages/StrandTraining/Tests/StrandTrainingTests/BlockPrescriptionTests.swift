import XCTest
@testable import StrandTraining

/// What a week of a block prescribes, and that it never writes any of it into the stored routine.
final class BlockPrescriptionTests: XCTestCase {

    private func routine(weight: Double = 100, workSets: Int = 3,
                         warmups: Int = 1) -> TrainingRoutine {
        let warm = (0..<warmups).map { _ in
            RoutineSetPlan(phase: .warmup, targetWeightKg: 40, repsMin: 8, repsMax: 8)
        }
        let work = (0..<workSets).map { _ in
            RoutineSetPlan(targetWeightKg: weight, repsMin: 5, repsMax: 5)
        }
        return TrainingRoutine(title: "Squat day", exercises: [
            RoutineExercise(exerciseId: "noop:back-squat", sets: warm + work, restSeconds: 180)
        ])
    }

    private func state(week: Int, weeks: Int = 8, deload: Bool = false,
                       factor: Double = 0.9) -> TrainingBlockState.State {
        TrainingBlockState.State(week: week, weeks: weeks, isDeload: deload, isFinished: false,
                                 loadFactor: deload ? factor : 1)
    }

    private func work(_ routine: TrainingRoutine) -> [RoutineSetPlan] {
        routine.exercises.first?.sets.filter { $0.phase == .work } ?? []
    }

    func testWithoutABlockNothingChanges() {
        let original = routine()
        XCTAssertEqual(BlockPrescription.apply(original, state: nil, policy: .weeklyLoad,
                                               weightStepKg: 2.5), original)
    }

    func testAPolicyOfNoneChangesNothingHowFarIntoTheBlockItIs() {
        let original = routine()
        XCTAssertEqual(BlockPrescription.apply(original, state: state(week: 5), policy: .none,
                                               weightStepKg: 2.5), original)
    }

    func testTheFirstWeekIsTheRoutineAsWritten() {
        let original = routine()
        XCTAssertEqual(BlockPrescription.apply(original, state: state(week: 1), policy: .weeklyLoad,
                                               weightStepKg: 2.5), original)
    }

    func testAWeeklyLoadBlockAddsOneStepAWeekToTheWorkSetsOnly() {
        let applied = BlockPrescription.apply(routine(), state: state(week: 4),
                                              policy: .weeklyLoad, weightStepKg: 2.5)
        // Week four is three steps on from week one.
        XCTAssertEqual(work(applied).map(\.targetWeightKg), [107.5, 107.5, 107.5])
        // The warm-up is not the work and is left alone.
        XCTAssertEqual(applied.exercises.first?.sets.first?.targetWeightKg, 40)
    }

    /// A set the plan left open carries no weight on purpose. Adding kilograms to it would invent a
    /// load nobody chose.
    func testASetWithoutAWeightIsNotGivenOne() {
        let open = TrainingRoutine(title: "Push-ups", exercises: [
            RoutineExercise(exerciseId: "noop:push-up",
                            sets: [RoutineSetPlan(repsMin: 10, repsMax: 15)], restSeconds: 90)
        ])
        let applied = BlockPrescription.apply(open, state: state(week: 5), policy: .weeklyLoad,
                                              weightStepKg: 2.5)
        XCTAssertNil(work(applied).first?.targetWeightKg)
    }

    func testAWeeklyVolumeBlockAddsASetAWeekUpToACeiling() {
        XCTAssertEqual(work(BlockPrescription.apply(routine(), state: state(week: 2),
                                                    policy: .weeklyVolume, weightStepKg: 2.5)).count, 4)
        XCTAssertEqual(work(BlockPrescription.apply(routine(), state: state(week: 4),
                                                    policy: .weeklyVolume, weightStepKg: 2.5)).count, 6)
        // However long the block runs, the session does not grow without end.
        XCTAssertEqual(work(BlockPrescription.apply(routine(), state: state(week: 12, weeks: 12),
                                                    policy: .weeklyVolume, weightStepKg: 2.5)).count,
                       3 + BlockPrescription.maxAddedSets)
    }

    func testALighterWeekKeepsItsShareOfTheLoadAndFewerSets() {
        let applied = BlockPrescription.apply(routine(weight: 100, workSets: 3),
                                              state: state(week: 8, deload: true, factor: 0.9),
                                              policy: .none, weightStepKg: 2.5)
        // Three sets at ninety per cent leaves two, each at ninety per cent of the load.
        XCTAssertEqual(work(applied).count, 2)
        XCTAssertEqual(work(applied).map(\.targetWeightKg), [90, 90])
        // The ramp is untouched.
        XCTAssertEqual(applied.exercises.first?.sets.first?.phase, .warmup)
        XCTAssertEqual(applied.exercises.first?.sets.first?.targetWeightKg, 40)
    }

    func testALighterWeekAlwaysLeavesAtLeastOneWorkSet() {
        let applied = BlockPrescription.apply(routine(workSets: 1),
                                              state: state(week: 4, deload: true, factor: 0.5),
                                              policy: .none, weightStepKg: 2.5)
        XCTAssertEqual(work(applied).count, 1)
    }

    /// The week's step first, then the lighter week on top of it: a lighter week keeps its share of
    /// THIS week's load, not of the load eight weeks ago.
    func testALighterWeekDampsTheWeeksOwnLoad() {
        let applied = BlockPrescription.apply(routine(weight: 100),
                                              state: state(week: 5, deload: true, factor: 0.9),
                                              policy: .weeklyLoad, weightStepKg: 2.5)
        XCTAssertEqual(work(applied).first?.targetWeightKg, 99) // (100 + 4 × 2.5) × 0.9
    }

    func testAFinishedBlockPrescribesTheRoutineAsWritten() {
        let original = routine()
        let finished = TrainingBlockState.State(week: 9, weeks: 8, isDeload: false, isFinished: true,
                                                loadFactor: 1)
        XCTAssertEqual(BlockPrescription.apply(original, state: finished, policy: .weeklyLoad,
                                               weightStepKg: 2.5), original)
    }

    /// The whole point of applying this on the way out: the routine in the store is still the first
    /// week, so nothing has to be repaired when the block ends.
    func testTheStoredRoutineIsNeverTouched() {
        let original = routine()
        let before = original.exercises.first?.sets
        _ = BlockPrescription.apply(original, state: state(week: 6, deload: true),
                                    policy: .weeklyVolume, weightStepKg: 2.5)
        XCTAssertEqual(original.exercises.first?.sets, before)
        XCTAssertEqual(work(original).map(\.targetWeightKg), [100, 100, 100])
        XCTAssertEqual(work(original).count, 3)
    }

    func testADurationSetIsDampedTooAndNeverToNothing() {
        let plank = TrainingRoutine(title: "Core", exercises: [
            RoutineExercise(exerciseId: "noop:plank",
                            sets: [RoutineSetPlan(targetDurationS: 60)], restSeconds: 60)
        ])
        let applied = BlockPrescription.apply(plank, state: state(week: 4, deload: true, factor: 0.5),
                                              policy: .none, weightStepKg: 2.5)
        XCTAssertEqual(work(applied).first?.targetDurationS, 30)
    }
}
