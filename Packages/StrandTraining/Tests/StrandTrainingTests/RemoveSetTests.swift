import XCTest
@testable import StrandTraining

/// Taking back a set that was added by mistake. The rule lived in the Apple session model alone, so
/// Android had no way to remove a set at all and a wearer who tapped "add set" once too often was stuck
/// with it (issue #43). It is the engine's now, and both platforms ask it.
final class RemoveSetTests: XCTestCase {

    private func draft(sets: [NativeWorkoutSet]) -> WorkoutDraft {
        WorkoutDraft(title: "Session", startedAt: 1_000, plannedDay: "2026-11-14",
                     exercises: [NativeWorkoutExercise(exerciseId: "bench", sets: sets)])
    }

    private func set(_ index: Int, parent: UUID? = nil) -> NativeWorkoutSet {
        NativeWorkoutSet(index: index, weightKg: 60, reps: 8, parentSetId: parent)
    }

    func testRemovingASetRenumbersWhatIsLeft() throws {
        var d = draft(sets: [set(0), set(1), set(2)])
        let middle = d.exercises[0].sets[1].id
        try NativeWorkoutEngine.removeSet(middle, from: d.exercises[0].id, in: &d)
        XCTAssertEqual(d.exercises[0].sets.count, 2)
        XCTAssertEqual(d.exercises[0].sets.map(\.index), [0, 1])
        XCTAssertFalse(d.exercises[0].sets.contains { $0.id == middle })
    }

    /// An exercise keeps at least one row; emptying it is removing the exercise, which has its own action.
    func testTheLastSetStays() throws {
        var d = draft(sets: [set(0)])
        let only = d.exercises[0].sets[0].id
        XCTAssertFalse(NativeWorkoutEngine.canRemoveSet(only, from: d.exercises[0].id, in: d))
        XCTAssertThrowsError(try NativeWorkoutEngine.removeSet(only, from: d.exercises[0].id, in: &d))
        XCTAssertEqual(d.exercises[0].sets.count, 1)
    }

    /// A set that drop-set segments hang off cannot be pulled out from under them.
    func testASetWithSegmentsStays() throws {
        var first = set(0)
        let origin = first.id
        first.index = 0
        var d = draft(sets: [first, set(1, parent: origin), set(2)])
        XCTAssertFalse(NativeWorkoutEngine.canRemoveSet(origin, from: d.exercises[0].id, in: d))
        XCTAssertThrowsError(try NativeWorkoutEngine.removeSet(origin, from: d.exercises[0].id, in: &d))
        XCTAssertEqual(d.exercises[0].sets.count, 3)
    }

    func testAnUnknownSetOrExerciseChangesNothing() throws {
        var d = draft(sets: [set(0), set(1)])
        XCTAssertFalse(NativeWorkoutEngine.canRemoveSet(UUID(), from: d.exercises[0].id, in: d))
        XCTAssertThrowsError(try NativeWorkoutEngine.removeSet(UUID(), from: d.exercises[0].id, in: &d))
        XCTAssertThrowsError(try NativeWorkoutEngine.removeSet(d.exercises[0].sets[0].id, from: UUID(), in: &d))
        XCTAssertEqual(d.exercises[0].sets.count, 2)
    }
}
