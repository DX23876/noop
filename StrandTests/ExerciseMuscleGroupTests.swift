import XCTest
import MuscleMap
import StrandTraining
@testable import Strand

/// The body picker's groups cover every muscle NOOP knows exactly once, draw where they are tapped, and
/// separate an exercise's main target from what it also trains.
final class ExerciseMuscleGroupTests: XCTestCase {
    func testEveryCatalogueMuscleBelongsToExactlyOneGroup() {
        for muscle in TrainingMuscleCatalog.all {
            let groups = ExerciseMuscleGroup.allCases.filter { $0.muscleIds.contains(muscle.id) }
            XCTAssertEqual(groups.count, 1, muscle.id)
        }
    }

    func testATappedBodyPartSelectsTheGroupThatDrawsIt() {
        for group in ExerciseMuscleGroup.allCases {
            XCTAssertFalse(group.renderedMuscles.isEmpty, group.rawValue)
            for muscle in group.renderedMuscles {
                XCTAssertEqual(ExerciseMuscleGroup.group(for: muscle), group, "\(group) \(muscle)")
            }
        }
    }

    func testMainTargetComesBeforeAlsoTrains() {
        let bench = TrainingExercise(id: "x:bench", title: "Unlisted press", mode: .weightReps,
                                     primaryMuscleId: "chest", secondaryMuscleIds: ["triceps"])
        XCTAssertEqual(ExerciseMuscleGroup.chest.involvement(of: bench), .primary)
        XCTAssertEqual(ExerciseMuscleGroup.triceps.involvement(of: bench), .secondary)
        XCTAssertNil(ExerciseMuscleGroup.calves.involvement(of: bench))
        let counts = ExerciseMuscleGroup.counts([bench])
        XCTAssertEqual(counts[.chest], 1)
        XCTAssertEqual(counts[.triceps], 1)
        XCTAssertNil(counts[.calves])
    }
}
