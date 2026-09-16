import XCTest
@testable import WhoopStore

/// The one mapping between NOOP's muscle ids and the groups the Strength analytics count in.
final class HevyMuscleGroupTaxonomyTests: XCTestCase {
    /// A group's own muscle ids map back to that group, so a mapping the wearer chose, expanded to muscles
    /// and counted again, lands where they put it.
    func testAGroupsMusclesMapBackToTheGroup() {
        for group in HevyMuscleGroup.allCases {
            for id in group.trainingMuscleIds {
                XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle(id), group, "\(group) \(id)")
            }
        }
    }

    /// Serratus, obliques, hip flexors and shins are their own groups — no longer folded into abs,
    /// abductors and calves, where a serratus set used to be counted as abdominal work.
    func testTheFourFinerGroupsAreNotFoldedIntoNeighbours() {
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle("serratus"), .serratus)
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle("obliques"), .obliques)
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle("hip_flexors"), .hipFlexors)
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle("tibialis"), .shins)
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle("lower_abs"), .abdominals)
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle("rhomboids"), .upperBack)
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle("not-a-muscle"), .other)
        XCTAssertEqual(HevyMuscleGroup.forTrainingMuscle(nil), .other)
    }

    /// Hevy's vocabulary stays exactly Hevy's: the four NOOP-only groups are never offered as a filter
    /// over a synced Hevy catalogue, which could not match them.
    func testHevysOwnGroupsExcludeTheNoopOnlyOnes() {
        XCTAssertEqual(HevyMuscleGroup.hevyGroups.count, 20)
        for group in [HevyMuscleGroup.serratus, .obliques, .hipFlexors, .shins] {
            XCTAssertFalse(HevyMuscleGroup.hevyGroups.contains(group))
        }
        XCTAssertEqual(HevyMuscleGroup.parse("hip_flexors"), .hipFlexors)
        XCTAssertEqual(HevyMuscleGroup.hipFlexors.label, "Hip flexors")
    }
}
