import XCTest
import StrandTraining
@testable import NoopCore

/// "Find by muscle" on Android reads the shared `ExerciseMuscleGroup`: every group, main targets before side ones.
final class CoreMuscleGroupTests: XCTestCase {
    func testGroupsSplitMainAndSideTargets() {
        let press = TrainingExercise(id: "press", title: "Press", mode: .weightReps,
                                     primaryMuscleId: "chest", secondaryMuscleIds: ["triceps"])
        let pushdown = TrainingExercise(id: "pushdown", title: "Pushdown", mode: .weightReps, primaryMuscleId: "triceps")
        let groups = CoreTrainingLibrary.groups([press, pushdown])
        XCTAssertEqual(groups.map(\.id), ExerciseMuscleGroup.allCases.map(\.rawValue))
        let chest = try? XCTUnwrap(groups.first { $0.id == "chest" })
        XCTAssertEqual(chest?.primary, ["press"])
        XCTAssertEqual(chest?.secondary, [])
        let triceps = groups.first { $0.id == "triceps" }
        XCTAssertEqual(triceps?.primary, ["pushdown"])
        XCTAssertEqual(triceps?.secondary, ["press"])
        XCTAssertEqual(groups.first { $0.id == "upperBack" }?.muscleIds, ["lats", "rhomboids", "upper_back"])
    }
}
