import XCTest
@testable import StrandTraining

final class WorkoutEntryTests: XCTestCase {
    func testSkippingKeepsCompletedSetsAndRenumbersThem() throws {
        var done = NativeWorkoutSet(index: 1, weightKg: 100, reps: 5)
        done.isCompleted = true
        let pending = NativeWorkoutSet(index: 0, weightKg: 100, reps: 5)
        let squat = NativeWorkoutExercise(exerciseId: "squat", sets: [pending, done])
        var draft = WorkoutDraft(title: "Legs", startedAt: 1, plannedDay: "1970-01-01", exercises: [squat])

        try NativeWorkoutEngine.skipRemainingSets(of: squat.id, in: &draft)

        XCTAssertEqual(draft.exercises[0].sets.map(\.id), [done.id])
        XCTAssertEqual(draft.exercises[0].sets[0].index, 0)
    }

    func testSkippingAnUntouchedExerciseRemovesItAndDissolvesItsSuperset() throws {
        let group = UUID()
        let row = NativeWorkoutExercise(exerciseId: "row", sets: [.init(index: 0)], supersetId: group)
        let curl = NativeWorkoutExercise(exerciseId: "curl", sets: [.init(index: 0)], supersetId: group)
        var draft = WorkoutDraft(title: "Pull", startedAt: 1, plannedDay: "1970-01-01", exercises: [row, curl])

        try NativeWorkoutEngine.skipRemainingSets(of: row.id, in: &draft)

        XCTAssertEqual(draft.exercises.map(\.exerciseId), ["curl"])
        XCTAssertNil(draft.exercises[0].supersetId)
        XCTAssertThrowsError(try NativeWorkoutEngine.skipRemainingSets(of: UUID(), in: &draft))
    }

    func testCompletedSegmentOfASkippedOriginBecomesAnOrdinarySet() throws {
        let origin = NativeWorkoutSet(index: 0, weightKg: 60, reps: 8)
        var segment = NativeWorkoutSet(index: 1, intensifier: .dropSet, weightKg: 45, reps: 6,
                                       parentSetId: origin.id, segmentIndex: 1)
        segment.isCompleted = true
        let press = NativeWorkoutExercise(exerciseId: "press", sets: [origin, segment])
        var draft = WorkoutDraft(title: "Push", startedAt: 1, plannedDay: "1970-01-01", exercises: [press])

        try NativeWorkoutEngine.skipRemainingSets(of: press.id, in: &draft)

        XCTAssertEqual(draft.exercises[0].sets.count, 1)
        XCTAssertNil(draft.exercises[0].sets[0].parentSetId)
        XCTAssertNil(draft.exercises[0].sets[0].segmentIndex)
    }

    func testBarbellStepsByTwoSmallestPlatesAndOtherEquipmentByTheSetting() {
        XCTAssertEqual(WeightIncrement.step(equipmentIds: ["barbell", "bench"], platePairsKg: [20, 1.25, 5],
                                            fallbackKg: 2), 2.5)
        XCTAssertEqual(WeightIncrement.step(equipmentIds: ["dumbbell"], platePairsKg: [1.25], fallbackKg: 2), 2)
        XCTAssertEqual(WeightIncrement.step(equipmentIds: ["barbell"], platePairsKg: [], fallbackKg: 2.5), 2.5)
        XCTAssertEqual(WeightIncrement.step(equipmentIds: ["machine"], platePairsKg: [], fallbackKg: 0), 0.25)
    }
}
