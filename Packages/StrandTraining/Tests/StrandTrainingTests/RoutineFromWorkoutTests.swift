import XCTest
@testable import StrandTraining

/// A session that has been done, turned into a routine that can be done again.
final class RoutineFromWorkoutTests: XCTestCase {

    private func set(_ reps: Int?, _ weight: Double?, phase: TrainingSetPhase = .work,
                     completed: Bool = true, duration: Int? = nil) -> NativeWorkoutSet {
        var value = NativeWorkoutSet(index: 0, phase: phase, weightKg: weight, reps: reps,
                                     durationS: duration)
        value.isCompleted = completed
        return value
    }

    private func workout(_ exercises: [NativeWorkoutExercise]) -> NativeWorkout {
        NativeWorkout(id: UUID(), title: "Freestyle", startedAt: 1_000, endedAt: 4_600,
                      plannedDay: "2026-11-14", routineIds: [], exercises: exercises, tracker: nil)
    }

    func testWhatWasPerformedBecomesThePrescription() {
        let logged = NativeWorkoutExercise(
            exerciseId: "noop:back-squat",
            sets: [set(8, 40, phase: .warmup), set(5, 100), set(5, 100), set(4, 100)],
            restSeconds: 180, warmupRestSeconds: 45)
        let routine = RoutineFromWorkout.make(workout: workout([logged]), title: "Monday")

        XCTAssertEqual(routine?.title, "Monday")
        XCTAssertEqual(routine?.exercises.count, 1)
        let entry = routine?.exercises.first
        XCTAssertEqual(entry?.exerciseId, "noop:back-squat")
        XCTAssertEqual(entry?.restSeconds, 180)
        XCTAssertEqual(entry?.warmupRestSeconds, 45)
        XCTAssertEqual(entry?.sets.count, 4)
        // The warm-up stays a warm-up, so a ramp does not come back as working volume.
        XCTAssertEqual(entry?.sets.first?.phase, .warmup)
        XCTAssertEqual(entry?.sets.first?.targetWeightKg, 40)
        // The work sets did not all hit the same number, so the range is what happened.
        let work = entry?.sets.filter { $0.phase == .work } ?? []
        XCTAssertEqual(work.count, 3)
        XCTAssertTrue(work.allSatisfy { $0.repsMin == 4 && $0.repsMax == 5 })
        XCTAssertTrue(work.allSatisfy { $0.targetWeightKg == 100 })
        // The routine's own default applies; a converted exercise carries no progression of its own.
        XCTAssertNil(entry?.progression)
    }

    func testEverySetAtTheSameNumberKeepsThatNumber() {
        let logged = NativeWorkoutExercise(exerciseId: "x", sets: [set(5, 80), set(5, 80), set(5, 80)],
                                           restSeconds: 150)
        let exact = RoutineFromWorkout.make(workout: workout([logged]), title: "A")
        XCTAssertTrue(exact?.exercises.first?.sets.allSatisfy { $0.repsMin == 5 && $0.repsMax == 5 } == true)

        // A caller may ask for a little room, and gets exactly as much as it asked for.
        let opened = RoutineFromWorkout.make(workout: workout([logged]), title: "A", repSpan: 2)
        XCTAssertTrue(opened?.exercises.first?.sets.allSatisfy { $0.repsMin == 5 && $0.repsMax == 7 } == true)
    }

    func testASetNobodyCompletedIsNotInIt() {
        let logged = NativeWorkoutExercise(exerciseId: "x",
                                           sets: [set(5, 80), set(nil, nil, completed: false)],
                                           restSeconds: 120)
        let routine = RoutineFromWorkout.make(workout: workout([logged]), title: "A")
        XCTAssertEqual(routine?.exercises.first?.sets.count, 1)
    }

    func testAnExerciseWithoutACompletedSetIsDroppedAndAnEmptySessionGivesNothing() {
        let empty = NativeWorkoutExercise(exerciseId: "x",
                                          sets: [set(nil, nil, completed: false)], restSeconds: 120)
        let done = NativeWorkoutExercise(exerciseId: "y", sets: [set(10, 20)], restSeconds: 120)
        let mixed = RoutineFromWorkout.make(workout: workout([empty, done]), title: "A")
        XCTAssertEqual(mixed?.exercises.map(\.exerciseId), ["y"])
        XCTAssertNil(RoutineFromWorkout.make(workout: workout([empty]), title: "A"))
        XCTAssertNil(RoutineFromWorkout.make(workout: workout([]), title: "A"))
    }

    func testTheSameMovementLoggedTwiceBecomesOneEntry() {
        let first = NativeWorkoutExercise(exerciseId: "x", sets: [set(5, 80)], restSeconds: 120)
        let again = NativeWorkoutExercise(exerciseId: "x", sets: [set(3, 90)], restSeconds: 120)
        let routine = RoutineFromWorkout.make(workout: workout([first, again]), title: "A")
        XCTAssertEqual(routine?.exercises.count, 1)
        XCTAssertEqual(routine?.exercises.first?.sets.count, 2)
        XCTAssertEqual(routine?.exercises.first?.sets.map(\.targetWeightKg), [80, 90])
    }

    /// A pair done side by side comes back as a pair, under its own fresh identity so editing the
    /// routine cannot reach back into the logged session.
    func testASupersetComesBackAsASupersetWithFreshIdentity() {
        let group = UUID()
        let a = NativeWorkoutExercise(exerciseId: "a", sets: [set(10, 20)], restSeconds: 90,
                                      supersetId: group)
        let b = NativeWorkoutExercise(exerciseId: "b", sets: [set(10, 20)], restSeconds: 90,
                                      supersetId: group)
        let routine = RoutineFromWorkout.make(workout: workout([a, b]), title: "A")
        let ids = routine?.exercises.compactMap(\.supersetId) ?? []
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertNotEqual(ids.first, group)
    }

    func testADurationSetKeepsWhatWasHeld() {
        let logged = NativeWorkoutExercise(exerciseId: "noop:plank",
                                           sets: [set(nil, nil, duration: 50)], restSeconds: 60)
        let routine = RoutineFromWorkout.make(workout: workout([logged]), title: "A")
        XCTAssertEqual(routine?.exercises.first?.sets.first?.targetDurationS, 50)
        XCTAssertNil(routine?.exercises.first?.sets.first?.repsMin)
    }

    func testItGoesIntoThePlanItWasAskedFor() {
        let plan = UUID()
        let logged = NativeWorkoutExercise(exerciseId: "x", sets: [set(5, 80)], restSeconds: 120)
        let routine = RoutineFromWorkout.make(workout: workout([logged]), title: "A", programId: plan)
        XCTAssertEqual(routine?.programId, plan)
    }
}

extension RoutineFromWorkoutTests {

    private func clustered(_ cluster: UUID, _ index: Int, reps: Int, weight: Double)
        -> NativeWorkoutSet {
        var set = NativeWorkoutSet(index: index, intensifier: .dropSet, weightKg: weight, reps: reps)
        set.isCompleted = true
        set.clusterId = cluster
        set.segmentIndex = index
        return set
    }

    /// A technique keeps what the log can actually show: how many segments it had, and for a drop set
    /// how far the load came down.
    func testADropSetComesBackWithItsSegmentsAndItsDrop() {
        let cluster = UUID()
        let logged = NativeWorkoutExercise(exerciseId: "x", sets: [
            clustered(cluster, 0, reps: 8, weight: 100),
            clustered(cluster, 1, reps: 6, weight: 80)
        ], restSeconds: 120)
        let workout = NativeWorkout(id: UUID(), title: "Freestyle", startedAt: 1_000, endedAt: 4_600,
                                    plannedDay: "2026-11-14", routineIds: [], exercises: [logged],
                                    tracker: nil)
        let sets = RoutineFromWorkout.make(workout: workout, title: "A")?.exercises.first?.sets ?? []
        XCTAssertEqual(sets.count, 2)
        XCTAssertTrue(sets.allSatisfy { $0.intensifier == .dropSet })
        XCTAssertEqual(sets.first?.intensifierConfiguration?.segmentCount, 2)
        XCTAssertEqual(sets.first?.intensifierConfiguration?.loadReductionPercent ?? 0, 20,
                       accuracy: 0.001)
        // The log has no timing, so nothing is invented for a rest-pause's seconds.
        XCTAssertNil(sets.first?.intensifierConfiguration?.restPauseSeconds)
    }

    /// Naming a technique with nothing behind it is a prescription nobody can follow.
    func testAnIntensifierWithoutSegmentsComesBackAsAnOrdinarySet() {
        var set = NativeWorkoutSet(index: 0, intensifier: .restPause, weightKg: 90, reps: 5)
        set.isCompleted = true
        let logged = NativeWorkoutExercise(exerciseId: "x", sets: [set], restSeconds: 120)
        let workout = NativeWorkout(id: UUID(), title: "Freestyle", startedAt: 1_000, endedAt: 4_600,
                                    plannedDay: "2026-11-14", routineIds: [], exercises: [logged],
                                    tracker: nil)
        let plan = RoutineFromWorkout.make(workout: workout, title: "A")?.exercises.first?.sets.first
        XCTAssertEqual(plan?.intensifier, TrainingSetIntensifier.none)
        XCTAssertNil(plan?.intensifierConfiguration)
    }

    /// "As many as you can" and "to failure" say everything they mean in the name.
    func testAmrapKeepsItsNameWithoutSegments() {
        var set = NativeWorkoutSet(index: 0, intensifier: .amrap, weightKg: 60, reps: 14)
        set.isCompleted = true
        let logged = NativeWorkoutExercise(exerciseId: "x", sets: [set], restSeconds: 120)
        let workout = NativeWorkout(id: UUID(), title: "Freestyle", startedAt: 1_000, endedAt: 4_600,
                                    plannedDay: "2026-11-14", routineIds: [], exercises: [logged],
                                    tracker: nil)
        let plan = RoutineFromWorkout.make(workout: workout, title: "A")?.exercises.first?.sets.first
        XCTAssertEqual(plan?.intensifier, .amrap)
    }
}
