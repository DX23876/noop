import XCTest
import StrandTraining
import WhoopStore
@testable import Strand

/// A Hevy routine has to land on the exercises the wearer already logs in NOOP, or every import would
/// add a second "Bench Press" beside the first.
final class HevyRoutineImportTests: XCTestCase {
    private let starterBench = TrainingExercise(id: "noop:barbell-bench-press", title: "Barbell Bench Press",
                                                mode: .weightReps, equipmentIds: ["barbell", "bench"], source: .noop)
    private let catalogBench = TrainingExercise(id: "exdb:0025", title: "Barbell Bench Press", mode: .weightReps,
                                                equipmentIds: ["barbell"], source: .exerciseDB, sourceId: "0025")
    private let dumbbellBench = TrainingExercise(id: "exdb:0289", title: "Dumbbell Bench Press", mode: .weightReps,
                                                 equipmentIds: ["dumbbell"], source: .exerciseDB, sourceId: "0289")

    private func template(_ id: String, _ title: String, equipment: HevyEquipment = .barbell,
                          type: String = "weight_reps") -> HevyExerciseTemplate {
        HevyExerciseTemplate(id: id, title: title, type: type, primaryMuscleGroup: .chest,
                             secondaryMuscleGroups: [.triceps], equipment: equipment, isCustom: false)
    }

    private func matcher(extra: [TrainingExercise] = []) -> HevyRoutineExerciseMatcher {
        HevyRoutineExerciseMatcher(
            exercises: [catalogBench, dumbbellBench, starterBench] + extra,
            templates: ["79D0BB3A": template("79D0BB3A", "Bench Press (Barbell)"),
                        "3601968B": template("3601968B", "Bench Press (Dumbbell)", equipment: .dumbbell),
                        "CUSTOM1": template("CUSTOM1", "Landmine Twist", equipment: .other, type: "reps_only")],
            aliases: [])
    }

    func testHevysEquipmentInBracketsFindsNoopsOwnExercise() throws {
        let barbell = try XCTUnwrap(matcher().match(title: "Bench Press (Barbell)", templateId: "79D0BB3A"))
        XCTAssertFalse(barbell.isNew)
        // NOOP's starter exercise wins over the catalogue entry for the same movement.
        XCTAssertEqual(barbell.exercise.id, "noop:barbell-bench-press")
        let dumbbell = try XCTUnwrap(matcher().match(title: "Bench Press (Dumbbell)", templateId: "3601968B"))
        XCTAssertEqual(dumbbell.exercise.id, "exdb:0289")
    }

    func testAnUnknownExerciseIsMadeFromHevysDescriptionAndReusedNextTime() throws {
        let first = try XCTUnwrap(matcher().match(title: "Landmine Twist", templateId: "CUSTOM1"))
        XCTAssertTrue(first.isNew)
        XCTAssertEqual(first.exercise.id, "imported:hevy:CUSTOM1")
        XCTAssertEqual(first.exercise.mode, .repetitions)
        XCTAssertEqual(first.exercise.primaryMuscleId, HevyMuscleGroup.chest.trainingMuscleIds.first)
        XCTAssertEqual(first.exercise.source, .imported)

        let again = try XCTUnwrap(matcher(extra: [first.exercise]).match(title: "Landmine Twist", templateId: "CUSTOM1"))
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.exercise.id, "imported:hevy:CUSTOM1")
    }

    func testHevyNamesAreTriedEquipmentFirst() {
        XCTAssertEqual(HevyRoutineExerciseMatcher.candidateNames("Bench Press (Barbell)"),
                       ["Barbell Bench Press", "Bench Press (Barbell)"])
        XCTAssertEqual(HevyRoutineExerciseMatcher.candidateNames("Plank"), ["Plank"])
        XCTAssertEqual(HevyRoutineExerciseMatcher.candidateNames("(Barbell)"), ["(Barbell)"])
    }
}
