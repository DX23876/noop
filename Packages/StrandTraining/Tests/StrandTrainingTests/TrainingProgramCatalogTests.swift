import XCTest
@testable import StrandTraining

/// The ready-made plans: every one has to produce a complete, resting plan whose routines point at
/// exercises the app actually ships, and the published ones have to carry their source.
final class TrainingProgramCatalogTests: XCTestCase {

    private var library: [TrainingExercise] {
        TrainingStarterCatalog.exercises + BundledExerciseCatalog.exercises
    }

    func testEveryTemplateBuildsAPlanWithRoutinesOnDaysAndNothingActive() {
        let known = Set(library.map(\.id))
        for template in TrainingProgramCatalog.templates(exercises: library) {
            let (program, routines) = template.make(1_000, 2.5)
            XCTAssertFalse(routines.isEmpty, template.id)
            XCTAssertFalse(program.isActive, template.id)
            XCTAssertNil(program.block?.startedOn, template.id)
            XCTAssertFalse(program.schedule.isEmpty, template.id)
            // Every routine belongs to the plan and every scheduled day names a routine of it.
            XCTAssertTrue(routines.allSatisfy { $0.programId == program.id }, template.id)
            let ids = Set(routines.map(\.id))
            XCTAssertTrue(program.schedule.values.flatMap { $0 }.allSatisfy(ids.contains), template.id)
            // Every prescribed exercise exists in the shipped library, or the plan would open with
            // rows naming nothing.
            for routine in routines {
                for entry in routine.exercises {
                    XCTAssertTrue(known.contains(entry.exerciseId),
                                  "\(template.id): \(entry.exerciseId) is not in the library")
                }
            }
        }
    }

    func testAPublishedProgrammeNamesItsSourceAndSaysWhatAWeekCannotHold() {
        let published = TrainingProgramCatalog.templates(exercises: library)
            .filter { $0.origin.kind == .published }
        XCTAssertEqual(published.count, 2)
        for template in published {
            XCTAssertNotNil(template.origin.name, template.id)
            XCTAssertNotNil(template.origin.attribution, template.id)
            let (program, _) = template.make(1_000, 2.5)
            XCTAssertEqual(program.origin.attribution, template.origin.attribution)
            // Both programmes alternate their sessions week by week, which a repeating week cannot
            // express. The plan has to say so rather than flatten it in silence.
            XCTAssertEqual(program.notes?.contains("alternate"), true, template.id)
        }
    }

    func testTheFiveByFiveSessionsAreFiveSetsOfFiveAndOneSetOnTheDeadlift() {
        guard let template = TrainingProgramCatalog.templates(exercises: library)
            .first(where: { $0.id == "stronglifts-5x5" }) else { return XCTFail("missing") }
        let (_, routines) = template.make(1_000, 2.5)
        XCTAssertEqual(routines.map(\.title), ["5×5 A", "5×5 B"])
        for routine in routines {
            for entry in routine.exercises {
                let work = entry.sets.filter { $0.phase == .work }
                XCTAssertTrue(work.allSatisfy { $0.repsMin == 5 && $0.repsMax == 5 }, entry.exerciseId)
                XCTAssertEqual(work.count, entry.exerciseId == "noop:deadlift" ? 1 : 5,
                               entry.exerciseId)
            }
        }
    }

    /// "5+" is a set with a lower bound and no upper one, which is what the programme prescribes and
    /// what the logger already understands.
    func testGreyskullTakesTheLastSetAsFarAsItGoes() {
        guard let template = TrainingProgramCatalog.templates(exercises: library)
            .first(where: { $0.id == "greyskull-lp" }) else { return XCTFail("missing") }
        let (_, routines) = template.make(1_000, 2.5)
        for routine in routines {
            for entry in routine.exercises {
                let work = entry.sets.filter { $0.phase == .work }
                XCTAssertEqual(work.count, 3, entry.exerciseId)
                XCTAssertEqual(work.last?.repsMin, 5)
                XCTAssertNil(work.last?.repsMax)
                XCTAssertEqual(entry.progression?.policy, .greyskullLP)
            }
        }
    }

    func testTheWearersWeightStepReachesEveryPrescription() {
        for template in TrainingProgramCatalog.templates(exercises: library) {
            let (_, routines) = template.make(1_000, 1.25)
            for routine in routines {
                for entry in routine.exercises where entry.progression != nil {
                    XCTAssertEqual(entry.progression?.weightIncrementKg, 1.25,
                                   "\(template.id): \(entry.exerciseId)")
                }
            }
        }
    }

    func testTheBodyWeightTemplatePrescribesNothingThatNeedsAGym() {
        guard let template = TrainingProgramCatalog.templates(exercises: library)
            .first(where: { $0.id == "own-bodyweight-3" }) else { return XCTFail("missing") }
        let (_, routines) = template.make(1_000, 2.5)
        let byId = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        for routine in routines {
            for entry in routine.exercises {
                XCTAssertTrue(TrainingEquipmentCatalog.matches(byId[entry.exerciseId]?.equipmentIds ?? [],
                                                               available: ["bodyweight", "bar"]),
                              byId[entry.exerciseId]?.title ?? entry.exerciseId)
            }
        }
    }
}
