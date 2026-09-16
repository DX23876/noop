import XCTest
import StrandTraining
import WhoopStore
@testable import Strand

final class TrainingDisplayNamesTests: XCTestCase {
    func testLegacyAndProviderEquipmentIdsResolveToTheSettingsVocabulary() {
        XCTAssertEqual(TrainingDisplayNames.canonicalEquipment("bar"), "pull-up-bar")
        XCTAssertEqual(TrainingDisplayNames.canonicalEquipment(" Rack "), "squat-rack")
        XCTAssertEqual(TrainingDisplayNames.canonicalEquipment("Resistance Band"), "band")
        XCTAssertEqual(TrainingDisplayNames.canonicalEquipment("body weight"), "bodyweight")
    }

    func testEquipmentFilterRequiresEveryItemAndNeverBodyweight() throws {
        let exercises = Dictionary(uniqueKeysWithValues: TrainingStarterCatalog.exercises.map { ($0.id, $0) })
        let pullUp = try XCTUnwrap(exercises["noop:pull-up"])
        let squat = try XCTUnwrap(exercises["noop:back-squat"])
        let pushUp = try XCTUnwrap(exercises["noop:push-up"])

        XCTAssertTrue(TrainingPreferences.exercise(pullUp, matches: ["pull-up-bar"]))
        XCTAssertFalse(TrainingPreferences.exercise(squat, matches: ["barbell"]))
        XCTAssertTrue(TrainingPreferences.exercise(squat, matches: ["barbell", "squat-rack"]))
        XCTAssertTrue(TrainingPreferences.exercise(pushUp, matches: ["dumbbell"]))
        XCTAssertTrue(TrainingPreferences.exercise(squat, matches: []))
    }

    /// The provenance badge is a claim about where a session came from, so every source has to name
    /// itself. A workout logged in NOOP being labelled as a Hevy sync is the failure this pins.
    func testEveryStrengthSourceNamesItselfAndNativeIsNeverCalledAnImport() {
        for source in StrengthDataSource.allCases {
            XCTAssertFalse(TrainingDisplayNames.strengthSource(source).isEmpty, source.rawValue)
        }
        let native = TrainingDisplayNames.strengthSource(.noopNative)
        XCTAssertNotEqual(native, TrainingDisplayNames.strengthSource(.hevyAPI))
        XCTAssertNotEqual(native, TrainingDisplayNames.strengthSource(.imported))
        XCTAssertEqual(TrainingDisplayNames.strengthSource(.hevyCSV),
                       TrainingDisplayNames.strengthSource(.hevyAPI))
    }

    func testEveryCatalogMuscleAndShippedEquipmentHasALocalizedName() {
        for muscle in TrainingMuscleCatalog.all {
            XCTAssertNotNil(TrainingDisplayNames.localizedMuscle(muscle.id), muscle.id)
        }
        let equipment = Set(TrainingPreferences.knownEquipment
            + TrainingStarterCatalog.exercises.flatMap(\.equipmentIds)
            + BundledExerciseCatalog.exercises.flatMap(\.equipmentIds)
            + ExerciseAnatomyCatalog.all.flatMap(\.equipmentIds))
        for id in equipment {
            XCTAssertNotNil(TrainingDisplayNames.localizedEquipment(TrainingDisplayNames.canonicalEquipment(id)), id)
        }
    }
}
