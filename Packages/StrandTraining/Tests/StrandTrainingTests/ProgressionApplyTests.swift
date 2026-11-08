import XCTest
@testable import StrandTraining

/// How a progression prescription reaches the sets of a session that is starting. A tester's routine
/// planned a pyramid (80, 95, 105 kg) and every set started at the heaviest weight, with progression
/// switched off as well as on.
final class ProgressionApplyTests: XCTestCase {
    private func sets(_ weights: [Double?], reps: [Int?]) -> [NativeWorkoutSet] {
        zip(weights, reps).enumerated().map { index, pair in
            NativeWorkoutSet(index: index, weightKg: pair.0, reps: pair.1)
        }
    }

    private func start(_ planned: [NativeWorkoutSet], policy: ProgressionPolicy,
                       history: [ProgressionSession], unilateral: Bool = false) -> [NativeWorkoutSet] {
        var result = planned
        let reference = ProgressionReference(workingSets: planned)
        let next = TrainingProgressionEngine.next(
            configuration: .init(policy: policy, repsMin: 8, repsMax: 10), history: history,
            mode: .weightReps, currentWeightKg: reference.weightKg, currentReps: reference.reps,
            currentSets: planned.count)
        TrainingProgressionEngine.apply(next, reference: reference, to: &result, unilateral: unilateral)
        return result
    }

    private let lastPyramid = ProgressionSession(weightKg: 105, completedReps: [10, 9, 8],
                                                 targetReps: [8, 8, 8])

    func testProgressionOffKeepsEveryPlannedWeight() {
        let planned = sets([80, 95, 105], reps: [8, 8, 8])
        let started = start(planned, policy: .off, history: [lastPyramid])
        XCTAssertEqual(started.map(\.weightKg), [80, 95, 105])
        XCTAssertEqual(started.map(\.reps), [8, 8, 8])
    }

    func testFirstSessionKeepsThePlan() {
        let planned = sets([80, 95, 105], reps: [10, 9, 8])
        let started = start(planned, policy: .linear, history: [])
        XCTAssertEqual(started.map(\.weightKg), [80, 95, 105])
        XCTAssertEqual(started.map(\.reps), [10, 9, 8])
    }

    func testLinearProgressionMovesThePyramidByOneStep() {
        let planned = sets([80, 95, 105], reps: [8, 8, 8])
        let started = start(planned, policy: .linear, history: [lastPyramid])
        XCTAssertEqual(started.map(\.weightKg), [82.5, 97.5, 107.5])
    }

    func testDoubleProgressionAddsOneRepetitionToEverySetAndKeepsWeights() {
        let planned = sets([80, 95, 105], reps: [10, 9, 8])
        let started = start(planned, policy: .doubleProgression, history: [lastPyramid])
        XCTAssertEqual(started.map(\.weightKg), [80, 95, 105])
        XCTAssertEqual(started.map(\.reps), [11, 10, 9])
    }

    func testTopOfRangeAddsWeightAndResetsRepetitionsWithoutFlatteningTheSets() {
        let top = ProgressionSession(weightKg: 105, completedReps: [10, 10, 10], targetReps: [8, 8, 8])
        let planned = sets([80, 95, 105], reps: [10, 10, 10])
        let started = start(planned, policy: .doubleProgression, history: [top])
        XCTAssertEqual(started.map(\.weightKg), [82.5, 97.5, 107.5])
        XCTAssertEqual(started.map(\.reps), [8, 8, 8])
    }

    func testASetWithoutAFigureTakesThePrescription() {
        let planned = sets([80, nil, 100], reps: [8, nil, 8])
        let started = start(planned, policy: .linear, history: [
            ProgressionSession(weightKg: 100, completedReps: [8, 8, 8], targetReps: [8, 8, 8])])
        XCTAssertEqual(started.map(\.weightKg), [82.5, 102.5, 102.5])
        XCTAssertEqual(started.map(\.reps), [8, 8, 8])
    }

    func testWarmupsAreNotMoved() {
        var planned = sets([40, 80, 100], reps: [10, 8, 8])
        planned[0].phase = .warmup
        let started = start(planned, policy: .linear, history: [
            ProgressionSession(weightKg: 100, completedReps: [8, 8], targetReps: [8, 8])])
        XCTAssertEqual(started.map(\.weightKg), [40, 82.5, 102.5])
    }

    func testUnilateralSidesMoveTogether() {
        let planned = [NativeWorkoutSet(index: 0, weightKg: 20, leftReps: 9, rightReps: 8),
                       NativeWorkoutSet(index: 1, weightKg: 20, leftReps: 8, rightReps: 8)]
        let last = ProgressionSession(weightKg: 20, completedReps: [8, 8], targetReps: [8, 8])
        let started = start(planned, policy: .doubleProgression, history: [last], unilateral: true)
        XCTAssertEqual(started.map(\.leftReps), [10, 9])
        XCTAssertEqual(started.map(\.rightReps), [9, 9])
        XCTAssertEqual(started.map(\.reps), [nil, nil])
    }
}
