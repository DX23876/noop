import XCTest
@testable import StrandTraining

final class TrainingRoutineImportTests: XCTestCase {
    private let bench = TrainingExercise(id: "exdb:0025", title: "Barbell Bench Press", mode: .weightReps,
                                         source: .exerciseDB, sourceId: "0025")
    private let plank = TrainingExercise(id: "exdb:0464", title: "Front Plank", mode: .duration,
                                         source: .exerciseDB, sourceId: "0464")
    private let row = TrainingExercise(id: "exdb:0027", title: "Barbell Bent Over Row", mode: .weightReps,
                                       source: .exerciseDB, sourceId: "0027")
    private var catalog: [TrainingExercise] { [bench, plank, row] }

    // MARK: OpenGym

    private func openGymPlan(unit: String = "kg") -> Data {
        Data("""
        {"opengym_plan":1,"exported":"2026-10-18","name":"Test","unit":"\(unit)",
         "week":{"0":["r-push"],"3":["r-pull","r-gone"]},
         "routines":[
          {"id":"r-push","name":"Push","ex":[
            {"id":"0025","sets":3,"reps":8,"weight":100,"warmupSets":2,"restSec":150,"warmupRestSec":60,
             "intensifier":{"type":"dropset","count":2,"pct":20},"note":"Pause on the chest","sg":"a"},
            {"id":"c-1","sets":2,"repsMin":10,"repsMax":12,"sg":"a"},
            {"id":"0464","sets":3,"mode":"time","sec":45},
            {"id":"9999","sets":3,"reps":5},
            {"id":"0025","sets":2,"min":20,"speed":8}
          ]},
          {"id":"r-pull","name":"Pull","ex":[
            {"id":"0027","pyramid":[12,8,"Max"],"pyramidWeight":[60,70,0],"lastToFailure":true}
          ]}
         ],
         "customEx":[{"id":"c-1","n":"Landmine Press","bp":"shoulders","eq":"barbell"}]}
        """.utf8)
    }

    func testOpenGymPlanBecomesNoopRoutines() throws {
        let result = try OpenGymPlanImporter.parse(openGymPlan(), catalog: catalog, now: 1_000)
        XCTAssertEqual(result.routines.map(\.title), ["Push", "Pull"])
        // The unknown id and the cardio slot are left out and counted.
        XCTAssertEqual(result.skippedExercises, 2)
        XCTAssertEqual(result.newExercises.map(\.title), ["Landmine Press"])

        let push = result.routines[0]
        XCTAssertEqual(push.exercises.map(\.exerciseId), ["exdb:0025", result.newExercises[0].id, "exdb:0464"])
        let pressing = push.exercises[0]
        XCTAssertEqual(pressing.sets.map(\.phase), [.warmup, .warmup, .work, .work, .work, .work, .work])
        XCTAssertEqual(pressing.sets.map(\.intensifier), [.none, .none, .none, .none, .none, .dropSet, .dropSet])
        XCTAssertEqual(pressing.sets[2].targetWeightKg, 100)
        XCTAssertEqual(pressing.sets[2].repsMin, 8)
        XCTAssertEqual(pressing.sets[5].targetWeightKg ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(pressing.sets[6].targetWeightKg ?? 0, 64, accuracy: 0.001)
        XCTAssertEqual(pressing.restSeconds, 150)
        XCTAssertEqual(pressing.warmupRestSeconds, 60)
        XCTAssertEqual(pressing.note, "Pause on the chest")
        XCTAssertNotNil(pressing.supersetId)
        XCTAssertEqual(push.exercises[1].supersetId, pressing.supersetId)
        XCTAssertEqual(push.exercises[1].sets.map(\.repsMin), [10, 10])
        XCTAssertEqual(push.exercises[1].sets.map(\.repsMax), [12, 12])
        XCTAssertEqual(push.exercises[2].sets.map(\.targetDurationS), [45, 45, 45])
        XCTAssertEqual(push.exercises[2].restSeconds, 120)

        let pyramid = result.routines[1].exercises[0].sets
        XCTAssertEqual(pyramid.map(\.repsMin), [12, 8, nil])
        XCTAssertEqual(pyramid.map(\.targetWeightKg), [60, 70, nil])
        XCTAssertEqual(pyramid.map(\.intensifier), [.none, .none, .amrap])
    }

    func testOpenGymWeekUsesSundayZeroAndOnlyKnownRoutines() throws {
        let result = try OpenGymPlanImporter.parse(openGymPlan(), catalog: catalog)
        XCTAssertEqual(result.schedule[.sunday], [result.routines[0].id])
        XCTAssertEqual(result.schedule[.wednesday], [result.routines[1].id])
        XCTAssertEqual(result.schedule.count, 2)
        // The schedule is applied only when asked for.
        XCTAssertTrue(result.archive(includingSchedule: false, weekStartsOn: .monday).schedule.isEmpty)
        XCTAssertEqual(result.archive(includingSchedule: true, weekStartsOn: .monday).schedule.count, 2)
    }

    func testOpenGymPoundsArriveAsKilograms() throws {
        let result = try OpenGymPlanImporter.parse(openGymPlan(unit: "lb"), catalog: catalog)
        let set = try XCTUnwrap(result.routines[0].exercises[0].sets.first { $0.phase == .work })
        XCTAssertEqual(set.targetWeightKg ?? 0, 45.359237, accuracy: 0.000_001)
    }

    func testImportingTheSameRoutineAgainKeepsItsIdAndAnExistingExerciseIsReused() throws {
        let first = try OpenGymPlanImporter.parse(openGymPlan(), catalog: catalog)
        let mine = TrainingExercise(id: "user:landmine", title: "landmine press", mode: .weightReps, source: .user)
        let second = try OpenGymPlanImporter.parse(openGymPlan(), existingExercises: [mine], catalog: catalog)
        XCTAssertEqual(first.routines.map(\.id), second.routines.map(\.id))
        XCTAssertTrue(second.newExercises.isEmpty)
        XCTAssertEqual(second.routines[0].exercises[1].exerciseId, "user:landmine")
    }

    func testKeepingASubsetDropsItsScheduleEntriesAndUnusedExercises() throws {
        let result = try OpenGymPlanImporter.parse(openGymPlan(), catalog: catalog)
        let pullOnly = result.keeping([result.routines[1].id])
        XCTAssertEqual(pullOnly.routines.map(\.title), ["Pull"])
        XCTAssertEqual(pullOnly.schedule, [.wednesday: [result.routines[1].id]])
        XCTAssertTrue(pullOnly.newExercises.isEmpty)
    }

    func testAnythingElseIsNotAnOpenGymPlan() {
        XCTAssertThrowsError(try OpenGymPlanImporter.parse(Data("{\"routines\":[]}".utf8))) {
            XCTAssertEqual($0 as? TrainingRoutineImportError, .notAPlan)
        }
        XCTAssertThrowsError(try OpenGymPlanImporter.parse(Data("not json".utf8))) {
            XCTAssertEqual($0 as? TrainingRoutineImportError, .notAPlan)
        }
        let empty = Data("{\"opengym_plan\":1,\"routines\":[{\"id\":\"x\",\"name\":\"X\",\"ex\":[{\"id\":\"9999\"}]}]}".utf8)
        XCTAssertThrowsError(try OpenGymPlanImporter.parse(empty, catalog: catalog)) {
            XCTAssertEqual($0 as? TrainingRoutineImportError, .noRoutines)
        }
    }

    // MARK: Hevy

    private let hevyRoutine = Data("""
    {"id":"b459cba5-cd6d-463c-abd6-54f8eafcadcb","title":"Upper A","notes":"Heavy week","folder_id":null,
     "exercises":[
      {"index":1,"title":"Bent Over Row (Barbell)","exercise_template_id":"55E6546F","superset_id":0,
       "rest_seconds":90,"notes":"","sets":[{"index":0,"type":"normal","reps":10}]},
      {"index":0,"title":"Bench Press (Barbell)","exercise_template_id":"79D0BB3A","superset_id":0,
       "rest_seconds":180,"notes":"Touch and go",
       "sets":[
        {"index":0,"type":"warmup","weight_kg":60,"reps":5},
        {"index":1,"type":"normal","weight_kg":100,"rep_range":{"start":6,"end":8}},
        {"index":2,"type":"normal","weight_kg":null,"reps":null,"rep_range":{"start":6,"end":8}},
        {"index":3,"type":"dropset","weight_kg":80,"reps":8},
        {"index":4,"type":"failure"}
       ]},
      {"index":2,"title":"Mystery Machine","exercise_template_id":"CUSTOM1","sets":[{"index":0,"type":"normal","reps":12}]},
      {"index":3,"title":"Unknown","exercise_template_id":"ZZZ","sets":[{"index":0,"type":"normal","reps":12}]}
     ]}
    """.utf8)

    private func hevyMatch(_ title: String, _ templateId: String?) -> HevyRoutineExerciseMatch? {
        switch templateId {
        case "79D0BB3A": return .init(exercise: bench, isNew: false)
        case "55E6546F": return .init(exercise: row, isNew: false)
        case "CUSTOM1":
            return .init(exercise: TrainingExercise(id: "imported:hevy:custom1", title: title,
                                                    mode: .repetitions, source: .imported), isNew: true)
        default: return nil
        }
    }

    func testHevyRoutineKeepsPlannedSetsWithOnlyARepetitionRange() {
        let result = HevyRoutineImporter.parse([hevyRoutine], now: 1_000, match: hevyMatch)
        XCTAssertEqual(result.routines.count, 1)
        let routine = result.routines[0]
        XCTAssertEqual(routine.title, "Upper A")
        XCTAssertEqual(routine.notes, "Heavy week")
        // Hevy's own exercise order, not the document's.
        XCTAssertEqual(routine.exercises.map(\.exerciseId), ["exdb:0025", "exdb:0027", "imported:hevy:custom1"])
        XCTAssertEqual(result.skippedExercises, 1)
        XCTAssertEqual(result.newExercises.map(\.id), ["imported:hevy:custom1"])

        let pressing = routine.exercises[0]
        XCTAssertEqual(pressing.restSeconds, 180)
        XCTAssertEqual(pressing.note, "Touch and go")
        XCTAssertEqual(pressing.sets.map(\.phase), [.warmup, .work, .work, .work, .work])
        XCTAssertEqual(pressing.sets.map(\.intensifier), [.none, .none, .none, .dropSet, .failure])
        XCTAssertEqual(pressing.sets.map(\.repsMin), [5, 6, 6, 8, nil])
        XCTAssertEqual(pressing.sets.map(\.repsMax), [5, 8, 8, 8, nil])
        XCTAssertEqual(pressing.sets.map(\.targetWeightKg), [60, 100, nil, 80, nil])
        XCTAssertEqual(routine.exercises[1].supersetId, pressing.supersetId)
        XCTAssertNotNil(pressing.supersetId)
        XCTAssertNil(routine.exercises[1].note)
    }

    func testTheSameHevyRoutineKeepsItsNoopId() {
        let first = HevyRoutineImporter.parse([hevyRoutine], match: hevyMatch)
        let second = HevyRoutineImporter.parse([hevyRoutine], match: hevyMatch)
        XCTAssertEqual(first.routines.map(\.id), second.routines.map(\.id))
        XCTAssertNotEqual(first.routines.first?.id,
                          try OpenGymPlanImporter.parse(openGymPlan(), catalog: catalog).routines.first?.id)
    }
}
