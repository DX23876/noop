import XCTest
@testable import StrandTraining

/// Taking a finished workout's numbers back into the routine it was started from.
final class RoutineTargetUpdateTests: XCTestCase {
    private func routine(_ sets: [RoutineSetPlan], exercise: String = "lat_pulldown") -> TrainingRoutine {
        TrainingRoutine(title: "Pull", exercises: [RoutineExercise(exerciseId: exercise, sets: sets)],
                        createdAt: 1, updatedAt: 1)
    }

    private func workout(_ routine: TrainingRoutine, sets: [NativeWorkoutSet],
                         exercise: String = "lat_pulldown") -> NativeWorkout {
        NativeWorkout(id: UUID(), title: "Pull", startedAt: 100, endedAt: 200, plannedDay: "2026-11-08",
                      routineIds: [routine.id],
                      exercises: [NativeWorkoutExercise(exerciseId: exercise, routineId: routine.id, sets: sets)],
                      tracker: nil)
    }

    private func done(_ index: Int, _ kg: Double?, _ reps: Int?, phase: TrainingSetPhase = .work,
                      completed: Bool = true) -> NativeWorkoutSet {
        NativeWorkoutSet(index: index, phase: phase, weightKg: kg, reps: reps, isCompleted: completed)
    }

    func testHeavierSetsBecomeTheNewTargets() {
        let plan = routine([.init(targetWeightKg: 80, repsMin: 8, repsMax: 10),
                            .init(targetWeightKg: 95, repsMin: 8, repsMax: 10),
                            .init(targetWeightKg: 100, repsMin: 8, repsMax: 10)])
        let session = workout(plan, sets: [done(0, 80, 10), done(1, 97.5, 9), done(2, 105, 8)])
        let update = RoutineTargetUpdate.make(workout: session, routines: [plan], now: 500)
        XCTAssertEqual(update.changedSetCount, 2)
        XCTAssertEqual(update.exerciseIds, ["lat_pulldown"])
        let sets = update.routines.first?.exercises.first?.sets
        XCTAssertEqual(sets?.map(\.targetWeightKg), [80, 97.5, 105])
        XCTAssertEqual(sets?.map(\.repsMin), [8, 8, 8], "a count inside the range keeps the range")
        XCTAssertEqual(sets?.map(\.repsMax), [10, 10, 10])
        XCTAssertEqual(update.routines.first?.updatedAt, 500)
    }

    func testNothingChangesWhenTheWorkoutMatchedThePlan() {
        let plan = routine([.init(targetWeightKg: 60, repsMin: 5, repsMax: 5)])
        let update = RoutineTargetUpdate.make(workout: workout(plan, sets: [done(0, 60, 5)]),
                                              routines: [plan], now: 500)
        XCTAssertTrue(update.isEmpty)
        XCTAssertTrue(update.routines.isEmpty)
    }

    func testASingleRepetitionTargetIsReplacedAndARangeWidens() {
        let plan = routine([.init(targetWeightKg: 60, repsMin: 5, repsMax: 5),
                            .init(targetWeightKg: 60, repsMin: 8, repsMax: 10)])
        let session = workout(plan, sets: [done(0, 60, 6), done(1, 60, 12)])
        let sets = RoutineTargetUpdate.make(workout: session, routines: [plan], now: 1)
            .routines.first?.exercises.first?.sets
        XCTAssertEqual(sets?.map(\.repsMin), [6, 8])
        XCTAssertEqual(sets?.map(\.repsMax), [6, 12])
    }

    func testUnperformedAndWarmupSetsKeepTheirTargets() {
        let plan = routine([.init(phase: .warmup, targetWeightKg: 40, repsMin: 10, repsMax: 10),
                            .init(targetWeightKg: 80, repsMin: 8, repsMax: 10),
                            .init(targetWeightKg: 90, repsMin: 8, repsMax: 10)])
        let session = workout(plan, sets: [done(0, 50, 12, phase: .warmup),
                                           done(1, 85, 8),
                                           done(2, 100, 8, completed: false)])
        let sets = RoutineTargetUpdate.make(workout: session, routines: [plan], now: 1)
            .routines.first?.exercises.first?.sets
        XCTAssertEqual(sets?.map(\.targetWeightKg), [40, 85, 90])
    }

    func testSetsAddedInTheSessionAreNotAddedToTheRoutine() {
        let plan = routine([.init(targetWeightKg: 80, repsMin: 8, repsMax: 10)])
        let session = workout(plan, sets: [done(0, 82.5, 8), done(1, 82.5, 7)])
        let update = RoutineTargetUpdate.make(workout: session, routines: [plan], now: 1)
        XCTAssertEqual(update.routines.first?.exercises.first?.sets.count, 1)
        XCTAssertEqual(update.changedSetCount, 1)
    }

    func testRoutinesTheWorkoutDidNotUseAreLeftAlone() {
        let used = routine([.init(targetWeightKg: 80, repsMin: 8, repsMax: 10)])
        let other = routine([.init(targetWeightKg: 80, repsMin: 8, repsMax: 10)])
        let update = RoutineTargetUpdate.make(workout: workout(used, sets: [done(0, 90, 8)]),
                                              routines: [other, used], now: 1)
        XCTAssertEqual(update.routines.map(\.id), [used.id])
    }
}
