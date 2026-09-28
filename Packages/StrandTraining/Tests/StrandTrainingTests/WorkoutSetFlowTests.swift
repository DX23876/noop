import XCTest
@testable import StrandTraining

/// How numbers follow an edit, which set a hands-free step completes, when a set may be logged without
/// looking at it, and what an exercise added mid-session starts with.
final class WorkoutSetFlowTests: XCTestCase {
    private func exercise(_ id: String, weights: [Double?], reps: Int? = 8, done: Int = 0,
                          superset: UUID? = nil) -> NativeWorkoutExercise {
        NativeWorkoutExercise(exerciseId: id,
                              sets: weights.enumerated().map { index, weight in
                                  NativeWorkoutSet(index: index, weightKg: weight, reps: reps,
                                                   isCompleted: index < done)
                              },
                              supersetId: superset)
    }

    private func draft(_ exercises: [NativeWorkoutExercise], active: Int = 0) -> WorkoutDraft {
        var draft = WorkoutDraft(title: "Push", startedAt: 1, plannedDay: "1970-01-01", exercises: exercises)
        draft.cursor = ActiveExerciseCursor(exerciseId: exercises[active].id, setId: nil)
        return draft
    }

    private func weights(_ draft: WorkoutDraft, _ exercise: Int = 0) -> [Double?] {
        draft.exercises[exercise].sets.map(\.weightKg)
    }

    // MARK: - Following an edit

    func testLaterSetsRidingAlongWithThePlanFollowAChangedWeight() {
        var d = draft([exercise("bench", weights: [60, 60, 60])])
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) { $0.weightKg = 65 }
        XCTAssertEqual(weights(d), [65, 65, 65])
        // Step by step, the way a stepper changes it, lands in the same place.
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) { $0.weightKg = 67.5 }
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) { $0.weightKg = 70 }
        XCTAssertEqual(weights(d), [70, 70, 70])
    }

    func testAPlannedPyramidKeepsItsSteps() {
        var d = draft([exercise("bench", weights: [60, 70, 80])])
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) { $0.weightKg = 62.5 }
        XCTAssertEqual(weights(d), [62.5, 70, 80])
    }

    func testOnlyLaterOpenSetsOfTheSamePhaseFollowAndNeverASegment() {
        var sets = (0..<5).map { NativeWorkoutSet(index: $0, weightKg: 60, reps: 8) }
        sets[0].phase = .warmup
        sets[2].isCompleted = true
        sets[4].parentSetId = sets[3].id
        sets[4].intensifier = .dropSet
        var d = draft([NativeWorkoutExercise(exerciseId: "bench", sets: sets)])
        NativeWorkoutEngine.editSet(1, ofExercise: 0, in: &d) { $0.weightKg = 65 }
        // Warm-up before it, completed set 2 and the drop-set segment 4 keep 60; open work set 3 follows.
        XCTAssertEqual(weights(d), [60, 65, 60, 65, 60])
    }

    func testCorrectingACompletedSetStillMovesTheOpenSetsAfterIt() {
        var d = draft([exercise("bench", weights: [60, 60, 60], done: 1)])
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) { $0.weightKg = 62.5 }
        XCTAssertEqual(weights(d), [62.5, 62.5, 62.5])
    }

    func testAClearedValueStaysOnTheEditedSet() {
        var d = draft([exercise("bench", weights: [60, 60])])
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) { $0.weightKg = nil }
        XCTAssertEqual(weights(d), [nil, 60])
    }

    func testEmptyLaterSetsTakeTheFirstNumberTyped() {
        var d = draft([exercise("curl", weights: [nil, nil, nil])])
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) { $0.weightKg = 12.5 }
        XCTAssertEqual(weights(d), [12.5, 12.5, 12.5])
    }

    func testRepsFollowButEffortNever() {
        var d = draft([exercise("bench", weights: [60, 60])])
        NativeWorkoutEngine.editSet(0, ofExercise: 0, in: &d) {
            $0.reps = 10
            $0.effort = TrainingEffortRating(scale: .rpe, value: 8)
        }
        XCTAssertEqual(d.exercises[0].sets.map(\.reps), [10, 10])
        XCTAssertNil(d.exercises[0].sets[1].effort)
    }

    // MARK: - The next open set

    private func next(_ draft: WorkoutDraft) -> [Int]? {
        NativeWorkoutEngine.nextOpenSet(in: draft).map { [$0.exercise, $0.set] }
    }

    func testAStepCompletesTheActiveExercisesNextOpenSet() {
        XCTAssertEqual(next(draft([exercise("bench", weights: [60, 60, 60], done: 1),
                                   exercise("row", weights: [50, 50])])), [0, 1])
    }

    func testAFinishedExerciseMovesTheStepOnToTheNextOneWithWorkLeft() {
        XCTAssertEqual(next(draft([exercise("bench", weights: [60, 60], done: 2),
                                   exercise("fly", weights: [10], done: 1),
                                   exercise("row", weights: [50, 50])])), [2, 0])
        // It wraps: an exercise earlier in the list that still has an open set is not forgotten.
        XCTAssertEqual(next(draft([exercise("bench", weights: [60, 60], done: 1),
                                   exercise("row", weights: [50], done: 1)], active: 1)), [0, 1])
    }

    func testASupersetAlternatesBetweenItsMembers() {
        let group = UUID()
        XCTAssertEqual(next(draft([exercise("a", weights: [20, 20], done: 1, superset: group),
                                   exercise("b", weights: [20, 20], superset: group)])), [1, 0])
        XCTAssertEqual(next(draft([exercise("a", weights: [20, 20], done: 1, superset: group),
                                   exercise("b", weights: [20, 20], done: 1, superset: group)], active: 1)), [0, 1])
        // An exercise outside the group takes no part in the alternation.
        XCTAssertEqual(next(draft([exercise("a", weights: [20, 20], done: 1, superset: group),
                                   exercise("c", weights: [20, 20]),
                                   exercise("b", weights: [20, 20], superset: group)])), [2, 0])
    }

    func testNothingLeftMeansNoSet() {
        XCTAssertNil(next(draft([exercise("bench", weights: [60], done: 1)])))
    }

    // MARK: - Loggable without looking

    func testLoadedWorkNeedsAWeightAndRepetitions() {
        let full = NativeWorkoutSet(index: 0, weightKg: 60, reps: 8)
        XCTAssertTrue(NativeWorkoutEngine.hasLoggableValues(full, mode: .weightReps))
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(NativeWorkoutSet(index: 0, reps: 8), mode: .weightReps))
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(NativeWorkoutSet(index: 0, weightKg: 60),
                                                             mode: .weightedBodyweight))
    }

    func testBodyweightTimedAndDistanceWorkNeedOnlyTheirOwnNumber() {
        XCTAssertTrue(NativeWorkoutEngine.hasLoggableValues(NativeWorkoutSet(index: 0, leftReps: 8, rightReps: 8),
                                                            mode: .bodyweightReps))
        XCTAssertTrue(NativeWorkoutEngine.hasLoggableValues(NativeWorkoutSet(index: 0, durationS: 60), mode: .duration))
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(NativeWorkoutSet(index: 0, reps: 8), mode: .duration))
        XCTAssertTrue(NativeWorkoutEngine.hasLoggableValues(NativeWorkoutSet(index: 0, distanceM: 500),
                                                            mode: .distanceDuration))
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(NativeWorkoutSet(index: 0), mode: nil))
    }

    // MARK: - An exercise added mid-session

    func testAnAddedExerciseStartsFromItsLastPerformanceSetBySet() {
        var warmup = NativeWorkoutSet(index: 0, phase: .warmup, weightKg: 40, reps: 10)
        warmup.isCompleted = true
        warmup.effort = TrainingEffortRating(scale: .rpe, value: 5)
        let work = NativeWorkoutSet(index: 1, weightKg: 80, reps: 6, isCompleted: true)
        let sets = NativeWorkoutEngine.setsForAddedExercise(lastPerformance: [warmup, work], unilateral: false)
        XCTAssertEqual(sets.map(\.phase), [.warmup, .work])
        XCTAssertEqual(sets.map(\.weightKg), [40, 80])
        XCTAssertEqual(sets.map(\.reps), [10, 6])
        XCTAssertEqual(sets.map(\.index), [0, 1])
        // Completion and effort belong to the earlier session, never to the new rows.
        XCTAssertFalse(sets.contains(where: \.isCompleted))
        XCTAssertTrue(sets.allSatisfy { $0.effort == nil })
    }

    func testWithoutHistoryTheWeightIsLeftEmptyNotZero() {
        let plain = NativeWorkoutEngine.setsForAddedExercise(lastPerformance: [], unilateral: false)
        XCTAssertEqual(plain.count, 1)
        XCTAssertNil(plain[0].weightKg)
        XCTAssertEqual(plain[0].reps, 8)
        let sides = NativeWorkoutEngine.setsForAddedExercise(lastPerformance: [], unilateral: true)
        XCTAssertEqual([sides[0].leftReps, sides[0].rightReps, sides[0].reps], [8, 8, nil])
    }
}
