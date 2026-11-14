import XCTest
import GRDB
import StrandTraining
@testable import WhoopStore

/// v90: routines and scheduled days gain a plan, and only the plans being followed answer the one
/// question every surface asks ("what do I train today").
final class TrainingProgramStoreTests: XCTestCase {

    /// The whole point of the migration: a wearer who had routines and a week before plans existed
    /// keeps both, in one plan that is already active, so nothing disappears from Today.
    func testV90MovesEveryExistingRoutineAndDayIntoOneActivePlan() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v89-workout-route")
        let routineId = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO trainingRoutineNative
                  (id, title, notes, defaultProgressionJSON, excludeFromProgression, createdAtTs, updatedAtTs)
                VALUES (?, 'Legacy push', NULL, '{"policy":"off","weightIncrementKg":2.5,
                        "durationIncrementS":5,"repsMin":6,"repsMax":10,"failuresBeforeDeload":3,
                        "deloadFactor":0.9,"bodyweightMaxSets":6}', 0, 100, 200)
                """, arguments: [routineId])
            try db.execute(sql: "INSERT INTO trainingSchedule (weekday, idx, routineId) VALUES (1, 0, ?)",
                           arguments: [routineId])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let programs = try Row.fetchAll(db, sql: "SELECT * FROM trainingProgram")
            XCTAssertEqual(programs.count, 1)
            XCTAssertEqual(programs[0]["kind"] as String, "strength")
            XCTAssertEqual(programs[0]["isActive"] as Bool, true)
            let programId: String = programs[0]["id"]

            let routine = try Row.fetchOne(db, sql: "SELECT * FROM trainingRoutineNative")
            XCTAssertEqual(routine?["programId"] as String?, programId)
            XCTAssertEqual(routine?["title"] as String?, "Legacy push")

            let scheduled = try Row.fetchOne(db, sql: "SELECT * FROM trainingSchedule")
            XCTAssertEqual(scheduled?["programId"] as String?, programId)
            XCTAssertEqual(scheduled?["weekday"] as Int?, 1)
            XCTAssertEqual(scheduled?["routineId"] as String?, routineId)
        }
    }

    /// A fresh store has somewhere to put a first routine, so the hub is never a dead end.
    func testAFreshStoreStartsWithOneActivePlan() async throws {
        let store = try await WhoopStore.inMemory()
        let programs = try await store.trainingPrograms()
        XCTAssertEqual(programs.count, 1)
        XCTAssertTrue(programs[0].isActive)
    }

    func testARoutineThatNamesNoPlanJoinsThePlanBeingFollowed() async throws {
        let store = try await WhoopStore.inMemory()
        let active = try await store.trainingPrograms()[0]
        try await store.upsertTrainingRoutine(TrainingRoutine(title: "Push"))
        let stored = try await store.trainingRoutines()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].programId, active.id)
    }

    /// A plan the wearer has prepared but not taken up must not reach Today, the week or the quick
    /// start. They all read `trainingPlan`, so filtering here is what makes that true everywhere.
    func testOnlyActivePlansReachTheResolvedPlan() async throws {
        let store = try await WhoopStore.inMemory()
        let active = try await store.trainingPrograms()[0]
        let resting = TrainingProgram(title: "Next block")
        try await store.upsertTrainingProgram(resting)

        let followed = TrainingRoutine(title: "Followed", programId: active.id)
        let waiting = TrainingRoutine(title: "Waiting", programId: resting.id)
        try await store.upsertTrainingRoutine(followed)
        try await store.upsertTrainingRoutine(waiting)
        try await store.replaceTrainingSchedule([.monday: [followed.id]], programId: active.id)
        try await store.replaceTrainingSchedule([.monday: [waiting.id]], programId: resting.id)

        let plan = try await store.trainingPlan()
        XCTAssertEqual(plan.routines.map(\.title), ["Followed"])
        XCTAssertEqual(plan.schedule[.monday], [followed.id])
        XCTAssertEqual(plan.routines(day: "2026-11-16", weekday: .monday).map(\.title), ["Followed"])

        // Reading the resting plan is deliberate and still possible.
        let waitingRoutines = try await store.trainingRoutines(programId: resting.id)
        XCTAssertEqual(waitingRoutines.map(\.title), ["Waiting"])
    }

    func testTakingUpAPlanStandsDownTheOtherOneAndMergesNothingElse() async throws {
        let store = try await WhoopStore.inMemory()
        let first = try await store.trainingPrograms()[0]
        let second = TrainingProgram(title: "Second")
        try await store.upsertTrainingProgram(second)

        try await store.activateTrainingProgram(id: second.id, day: "2026-11-14", now: 5_000)
        let programs = try await store.trainingPrograms()
        XCTAssertEqual(programs.filter(\.isActive).map(\.id), [second.id])
        XCTAssertEqual(programs.first { $0.id == first.id }?.isActive, false)
    }

    func testAPlanWithABlockOpensARunWhenTakenUpAndClosesItWhenDropped() async throws {
        let store = try await WhoopStore.inMemory()
        let plan = TrainingProgram(title: "Eight weeks", block: TrainingProgramBlock(weeks: 8))
        try await store.upsertTrainingProgram(plan)

        try await store.activateTrainingProgram(id: plan.id, day: "2026-11-14", now: 5_000)
        var runs = try await store.trainingBlockRuns(programId: plan.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].startedOn, "2026-11-14")
        XCTAssertNil(runs[0].endedOn)
        XCTAssertEqual(runs[0].outcome, .running)

        try await store.deactivateTrainingProgram(id: plan.id, day: "2026-12-01", now: 6_000)
        runs = try await store.trainingBlockRuns(programId: plan.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].endedOn, "2026-12-01")
        XCTAssertEqual(runs[0].outcome, .abandoned)
    }

    /// Deleting a plan takes its routines and its week with it. Logged workouts are a different
    /// thing entirely and stay, which is what the delete dialog has always promised for a routine.
    func testDeletingAPlanRemovesItsRoutinesAndDaysAndLeavesTheOtherPlanAlone() async throws {
        let store = try await WhoopStore.inMemory()
        let keep = try await store.trainingPrograms()[0]
        let drop = TrainingProgram(title: "Drop me")
        try await store.upsertTrainingProgram(drop)
        let kept = TrainingRoutine(title: "Kept", programId: keep.id)
        let gone = TrainingRoutine(title: "Gone", programId: drop.id)
        try await store.upsertTrainingRoutine(kept)
        try await store.upsertTrainingRoutine(gone)
        try await store.replaceTrainingSchedule([.tuesday: [kept.id]], programId: keep.id)
        try await store.replaceTrainingSchedule([.tuesday: [gone.id]], programId: drop.id)

        try await store.deleteTrainingProgram(id: drop.id)

        let routines = try await store.trainingRoutines()
        XCTAssertEqual(routines.map(\.title), ["Kept"])
        let programs = try await store.trainingPrograms()
        XCTAssertEqual(programs.map(\.id), [keep.id])
        XCTAssertEqual(programs[0].schedule[.tuesday], [kept.id])
    }

    func testImportingAPlanFileLandsInOnePlanAndLeavesTheOthersUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        let followed = try await store.trainingPrograms()[0]
        let target = TrainingProgram(title: "Imported")
        try await store.upsertTrainingProgram(target)
        let mine = TrainingRoutine(title: "Mine", programId: followed.id)
        try await store.upsertTrainingRoutine(mine)
        try await store.replaceTrainingSchedule([.wednesday: [mine.id]], programId: followed.id)

        let incoming = TrainingRoutine(title: "From a file")
        let archive = TrainingPlanArchive(plan: TrainingPlan(routines: [incoming],
                                                              schedule: [.wednesday: [incoming.id]]),
                                          exercises: [])
        try await store.mergeTrainingPlan(archive, into: target.id, nowTs: 7_000)

        let programs = try await store.trainingPrograms()
        XCTAssertEqual(programs.first { $0.id == followed.id }?.schedule[.wednesday], [mine.id])
        XCTAssertEqual(programs.first { $0.id == target.id }?.schedule[.wednesday], [incoming.id])
        let imported = try await store.trainingRoutines(programId: target.id)
        XCTAssertEqual(imported.map(\.title), ["From a file"])
    }

    /// The order a built plan has to be written in: the plan without its week, then its routines,
    /// then the week. A scheduled day points at a routine and the store holds that, so a plan written
    /// WITH its week while the routines were still to come was refused outright and nothing was
    /// saved at all, which took the plan builder, the ready-made plans and every copy with it.
    func testAPlanAndItsWeekAreSavedTheWayABuiltPlanArrives() async throws {
        let store = try await WhoopStore.inMemory()
        let built = TrainingProgram(title: "Built")
        let session = TrainingRoutine(title: "Full body A", programId: built.id)
        let week: [TrainingWeekday: [UUID]] = [.monday: [session.id]]

        var resting = built
        resting.schedule = [:]
        try await store.upsertTrainingProgram(resting)
        try await store.upsertTrainingRoutine(session)
        try await store.replaceTrainingSchedule(week, programId: built.id)

        let stored = try await store.trainingPrograms().first { $0.id == built.id }
        XCTAssertEqual(stored?.schedule[.monday], [session.id])
        let routines = try await store.trainingRoutines(programId: built.id)
        XCTAssertEqual(routines.map(\.title), ["Full body A"])
    }

    /// Why that order is not a matter of taste: a week naming a routine that does not exist is
    /// refused, and the plan does not land half written either.
    func testAWeekNamingARoutineThatDoesNotExistIsRefusedWhole() async throws {
        let store = try await WhoopStore.inMemory()
        var early = TrainingProgram(title: "Too early")
        early.schedule = [.monday: [UUID()]]

        do {
            try await store.upsertTrainingProgram(early)
            XCTFail("a week pointing at a routine that does not exist must not be stored")
        } catch {
            // expected
        }
        let stored = try await store.trainingPrograms().first { $0.id == early.id }
        XCTAssertNil(stored, "the plan itself must not be left behind either")
    }

    /// The migration cannot name the plan in the wearer's language, so it does not name it at all and
    /// the screens show their own default. An English title stored here would outlive every
    /// translation.
    func testTheMigratedPlanCarriesNoName() async throws {
        let store = try await WhoopStore.inMemory()
        let programs = try await store.trainingPrograms()
        XCTAssertEqual(programs.map(\.title), [""])
    }
}
