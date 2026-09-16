import XCTest
@testable import StrandTraining

final class ExerciseCatalogIdentityTests: XCTestCase {
    func testShippedCatalogueSurvivesItsOwnValidation() {
        XCTAssertEqual(ExerciseAnatomyCatalog.validationIssues(), [])
    }

    /// The validation is the development tool for a catalogue revision, so it has to actually catch
    /// each class of mistake rather than only pass on today's content.
    func testValidationCatchesDuplicateIdsUnknownEquipmentAndModeContradictions() {
        let good = ExerciseAnatomy(id: "row", title: "Row", mode: .weightReps,
                                   movementPattern: .horizontalPull, primaryMuscleIds: ["upper_back"],
                                   equipmentIds: ["barbell"])
        let duplicate = ExerciseAnatomy(id: "row", title: "Another row", mode: .weightReps,
                                        movementPattern: .horizontalPull, primaryMuscleIds: ["lats"],
                                        equipmentIds: ["cable"])
        let unknownEquipment = ExerciseAnatomy(id: "odd", title: "Odd", mode: .weightReps,
                                               movementPattern: .other, primaryMuscleIds: ["chest"],
                                               equipmentIds: ["hovercraft"])
        let contradiction = ExerciseAnatomy(id: "pull", title: "Pull", mode: .bodyweightReps,
                                            movementPattern: .verticalPull, primaryMuscleIds: ["lats"],
                                            equipmentIds: ["barbell"])
        let unmapped = ExerciseAnatomy(id: "blank", title: "Blank", mode: .weightReps,
                                       movementPattern: .other, primaryMuscleIds: ["nonsense"])
        let unreviewed = ExerciseAnatomy(id: "draft", title: "Draft", mode: .weightReps,
                                         movementPattern: .other, primaryMuscleIds: ["chest"],
                                         equipmentIds: ["barbell"], confidence: .sourceFallback)

        let issues = ExerciseAnatomyCatalog.validationIssues(
            [good, duplicate, unknownEquipment, contradiction, unmapped, unreviewed])

        XCTAssertTrue(issues.contains { $0.contains("duplicate exercise id") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("unknown equipment hovercraft") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("bodyweight repetitions with a loaded implement") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("unknown muscle nonsense") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("is not reviewed") }, "\(issues)")
    }

    func testAnExplicitCanonicalIdBeatsNameAndEquipment() throws {
        let target = try XCTUnwrap(ExerciseAnatomyCatalog.all.first)
        let resolved = ExerciseAnatomyCatalog.resolve(title: "Something else entirely",
                                                      equipmentIds: ["kettlebell"], mode: .duration,
                                                      canonicalId: target.id)
        XCTAssertEqual(resolved?.id, target.id)
        XCTAssertNil(ExerciseAnatomyCatalog.resolve(title: "Something else entirely",
                                                    canonicalId: "not-in-the-catalogue"))
    }

    func testStarterExercisesCarryCanonicalIdentityAndProvenance() throws {
        let bench = try XCTUnwrap(TrainingStarterCatalog.exercises.first { $0.id == "noop:barbell-bench-press" })
        XCTAssertEqual(bench.canonicalId, "barbell-bench-press")
        XCTAssertEqual(bench.contentVersion, ExerciseAnatomyCatalog.version)
        XCTAssertEqual(bench.attribution, "NOOP")
        XCTAssertEqual(bench.loadSemantics, .totalExternalLoad)
        XCTAssertEqual(TrainingMuscleProjection.anatomy(for: bench)?.id, "barbell-bench-press")
    }

    func testBodyRegionsAndEquipmentSpellingsResolveToOneVocabulary() {
        XCTAssertEqual(TrainingBodyRegion.forMuscles(["upper_chest"]), .chest)
        XCTAssertEqual(TrainingBodyRegion.forMuscles(["lats", "biceps"]), .back)
        XCTAssertEqual(TrainingBodyRegion.forMuscles(["unknown", "calves"]), .legs)
        XCTAssertEqual(TrainingBodyRegion.forMuscles(["unknown"]), .other)

        XCTAssertEqual(TrainingEquipmentCatalog.canonical("Bar"), "pull-up-bar")
        XCTAssertEqual(TrainingEquipmentCatalog.canonical("power rack"), "squat-rack")
        XCTAssertTrue(TrainingEquipmentCatalog.isKnown("resistance band"))
        XCTAssertFalse(TrainingEquipmentCatalog.isKnown("hovercraft"))
        XCTAssertTrue(TrainingEquipmentCatalog.carriesExternalLoad(["bench", "dumbbell"]))
        XCTAssertFalse(TrainingEquipmentCatalog.carriesExternalLoad(["bench", "bodyweight"]))
    }

    func testADefinitionWrittenBeforeCanonicalIdentityStillDecodes() throws {
        let current = TrainingExercise(id: "noop:test", title: "Test", mode: .weightReps,
                                       primaryMuscleId: "chest", equipmentIds: ["barbell"],
                                       canonicalId: "barbell-bench-press", aliases: ["press"],
                                       contentVersion: 3, attribution: "NOOP",
                                       loadSemantics: .totalExternalLoad)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)) as? [String: Any])
        ["canonicalId", "aliases", "contentVersion", "attribution", "loadSemantics"].forEach {
            object.removeValue(forKey: $0)
        }
        let legacy = try JSONDecoder().decode(
            TrainingExercise.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(legacy.canonicalId)
        XCTAssertEqual(legacy.aliases, [])
        XCTAssertEqual(legacy.contentVersion, 0)
        XCTAssertNil(legacy.attribution)
        XCTAssertNil(legacy.loadSemantics)
        // The derived meaning is unchanged, which is what makes the columns additive.
        XCTAssertEqual(legacy.effectiveLoadSemantics, current.effectiveLoadSemantics)
    }
}
