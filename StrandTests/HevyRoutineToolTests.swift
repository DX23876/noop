import XCTest
import WhoopStore
@testable import Strand

/// Pins the coach's two write-adjacent strength tools against a real store.
///
/// The single most important property in this whole feature is here: **an exercise id the model made
/// up must not reach a draft.** Hevy identifies movements by opaque ids ("05293BCA"), and a language
/// model asked to write a routine will happily produce strings of exactly that shape that refer to
/// nothing — or, worse, that happen to be a different exercise. The catalogue check is what makes the
/// difference between a rejected tool call the model can recover from and a plausible-looking routine
/// nobody can trace back to a mistake.
@MainActor
final class HevyRoutineToolTests: XCTestCase {

    private func engine(seeding seed: (WhoopStore) async throws -> Void = { _ in }) async throws
        -> (AICoachEngine, HevyRoutineProposalStore) {
        let store = try await WhoopStore.inMemory()
        try await seed(store)
        let repo = Repository(deviceId: "hevy-tool-test-\(UUID().uuidString)")
        repo.setStoreForTesting(store)
        let defaults = UserDefaults(suiteName: "hevy.tool.tests.\(UUID().uuidString)")!
        return (AICoachEngine(repo: repo),
                HevyRoutineProposalStore(defaults: defaults, storageKey: "test", loading: false))
    }

    private var catalogue: [HevyExerciseTemplate] {
        [
            HevyExerciseTemplate(id: "05293BCA", title: "Bench Press (Barbell)", type: "weight_reps",
                                 primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps],
                                 equipment: .barbell, isCustom: false),
            HevyExerciseTemplate(id: "AAAA1111", title: "Squat (Barbell)", type: "weight_reps",
                                 primaryMuscleGroup: .quadriceps, secondaryMuscleGroups: [.glutes],
                                 equipment: .barbell, isCustom: false),
            HevyExerciseTemplate(id: "BBBB2222", title: "Leg Press (Machine)", type: "weight_reps",
                                 primaryMuscleGroup: .quadriceps, secondaryMuscleGroups: [],
                                 equipment: .machine, isCustom: false),
        ]
    }

    private func draftInput(templateId: String, sets: Int = 3) -> [String: Any] {
        [
            "title": "Push Day",
            "rationale": "Chest volume is low this week.",
            "exercises": [[
                "exercise_template_id": templateId,
                "sets": (0..<sets).map { _ in
                    ["type": "normal", "rep_range_start": 8, "rep_range_end": 12] as [String: Any]
                },
            ]],
        ]
    }

    // MARK: - THE check

    /// An id that is not in the user's catalogue fails the WHOLE draft, rather than being dropped from
    /// it. A routine silently missing the movement it was built around is worse than no routine, and
    /// the model gets a message it can act on.
    func testAnInventedExerciseIdIsRejectedAndNothingIsDrafted() async throws {
        let (coach, inbox) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        let reply = await coach.proposeHevyRoutineTool(input: draftInput(templateId: "DEADBEEF"),
                                                       proposalStore: inbox)

        XCTAssertTrue(reply.contains("Nothing drafted"), reply)
        XCTAssertTrue(reply.contains("find_hevy_exercises"),
                      "the model needs to be told how to recover: \(reply)")
        XCTAssertTrue(inbox.proposals.isEmpty, "a draft was stored despite the invalid id")
    }

    /// With no catalogue synced there is nothing to validate against, so no draft can be made at all —
    /// rather than one built on ids that could not be checked.
    func testWithoutACatalogueNoDraftIsPossible() async throws {
        let (coach, inbox) = try await engine()
        let reply = await coach.proposeHevyRoutineTool(input: draftInput(templateId: "05293BCA"),
                                                       proposalStore: inbox)
        XCTAssertTrue(reply.contains("Nothing drafted"), reply)
        XCTAssertTrue(inbox.proposals.isEmpty)
    }

    // MARK: - A valid draft

    func testAValidDraftIsStoredAsProposedAndSaysItWasNotSent() async throws {
        let (coach, inbox) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        let reply = await coach.proposeHevyRoutineTool(input: draftInput(templateId: "05293BCA"),
                                                       proposalStore: inbox)

        XCTAssertEqual(inbox.proposals.count, 1)
        let proposal = try XCTUnwrap(inbox.proposals.first)
        XCTAssertEqual(proposal.status, .proposed)
        XCTAssertEqual(proposal.title, "Push Day")
        XCTAssertEqual(proposal.exercises.count, 1)
        // The title comes from the CATALOGUE, not from the model: a draft that renamed the movement
        // would make the review screen show something other than what will be sent.
        XCTAssertEqual(proposal.exercises[0].title, "Bench Press (Barbell)")
        XCTAssertEqual(proposal.exercises[0].sets.count, 3)
        XCTAssertEqual(proposal.exercises[0].sets[0].repRangeStart, 8)

        // The wording the model is handed matters as much as the state: it must not go on to tell the
        // user their routine was created.
        XCTAssertTrue(reply.contains("NOT sent to Hevy"), reply)
        XCTAssertTrue(reply.lowercased().contains("review"), reply)
    }

    /// An exercise with no sets fails the draft rather than landing as an empty row somebody has to
    /// interpret in the gym.
    func testAnExerciseWithNoSetsFailsTheDraft() async throws {
        let (coach, inbox) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        let reply = await coach.proposeHevyRoutineTool(
            input: ["title": "Push", "exercises": [["exercise_template_id": "05293BCA", "sets": []]]],
            proposalStore: inbox)
        XCTAssertTrue(reply.contains("Nothing drafted"), reply)
        XCTAssertTrue(inbox.proposals.isEmpty)
    }

    /// An implausible load is clamped rather than dropped. Discarding the set would hide the mistake;
    /// clamping keeps it visible in the review screen where the user can see something is off.
    func testAnAbsurdWeightIsClampedNotDiscarded() async throws {
        let (coach, inbox) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        _ = await coach.proposeHevyRoutineTool(
            input: ["title": "Push",
                    "exercises": [["exercise_template_id": "05293BCA",
                                   "sets": [["type": "normal", "weight_kg": 9000, "reps": 5]]]]],
            proposalStore: inbox)
        let set = try XCTUnwrap(inbox.proposals.first?.exercises.first?.sets.first)
        XCTAssertEqual(set.weightKg, 600, "the ceiling, not the model's number, and not nothing")
    }

    /// An update needs a routine that actually exists. A guessed routine id would replace the wrong
    /// plan wholesale, which is unrecoverable from inside the app.
    func testAnUpdateToAnUnknownRoutineIsRejected() async throws {
        let (coach, inbox) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        var input = draftInput(templateId: "05293BCA")
        input["operation"] = "update"
        input["routine_id"] = "does-not-exist"
        let reply = await coach.proposeHevyRoutineTool(input: input, proposalStore: inbox)

        XCTAssertTrue(reply.contains("Nothing drafted"), reply)
        XCTAssertTrue(inbox.proposals.isEmpty)
    }

    /// A valid update carries the routine's previous contents, which is what lets the review screen show
    /// what would be REMOVED — the only protection against Hevy's full-replace `PUT`.
    func testAValidUpdateCarriesThePreviousContentsForTheDiff() async throws {
        let (coach, inbox) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
            // The stored document is what the server sent, exercises INCLUDED — that is the only
            // place a routine's contents live (`hevyRoutines()` returns an empty `exercises` array by
            // construction). A fixture that split the two would test a state the sync cannot produce.
            let document = """
            {"id":"r1","title":"Leg Day","updated_at":"2026-09-01T12:00:00Z","some_future_field":1,
             "exercises":[
               {"index":0,"title":"Squat (Barbell)","exercise_template_id":"AAAA1111",
                "sets":[{"index":0,"type":"normal","weight_kg":140,"reps":5}]},
               {"index":1,"title":"Leg Press (Machine)","exercise_template_id":"BBBB2222",
                "sets":[{"index":0,"type":"normal","weight_kg":200,"reps":10}]}]}
            """
            try await store.upsertHevyRoutines([
                HevyRoutine(id: "r1", title: "Leg Day", folderId: nil, notes: nil,
                            updatedAtTs: 1_788_282_000, exercises: [], rawJSON: document),
            ])
        }
        var input = draftInput(templateId: "AAAA1111")
        input["operation"] = "update"
        input["routine_id"] = "r1"
        input["title"] = "Leg Day"
        _ = await coach.proposeHevyRoutineTool(input: input, proposalStore: inbox)

        let proposal = try XCTUnwrap(inbox.proposals.first)
        XCTAssertEqual(proposal.operation, .update)
        let previous = try XCTUnwrap(proposal.previousExercises)
        XCTAssertEqual(previous.map(\.templateId), ["AAAA1111", "BBBB2222"])
        XCTAssertEqual(proposal.exercises.map(\.templateId), ["AAAA1111"],
                       "the draft drops Leg Press, which is exactly what the review screen must show")
        XCTAssertEqual(proposal.previousRawJSON?.contains("some_future_field"), true,
                       "the verbatim document is kept, so the previous version can be restored")
    }

    // MARK: - Exercise search

    func testTheSearchReturnsIdsAndFiltersByMuscleAndEquipment() async throws {
        let (coach, _) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        let byName = await coach.findHevyExercisesTool(query: "bench press", muscleGroup: nil,
                                                       equipment: nil, limit: 15)
        XCTAssertTrue(byName.contains("05293BCA"), byName)
        XCTAssertFalse(byName.contains("AAAA1111"), byName)

        let byMuscle = await coach.findHevyExercisesTool(query: nil, muscleGroup: "quadriceps",
                                                         equipment: nil, limit: 15)
        XCTAssertTrue(byMuscle.contains("AAAA1111"), byMuscle)
        XCTAssertTrue(byMuscle.contains("BBBB2222"), byMuscle)
        XCTAssertFalse(byMuscle.contains("05293BCA"), byMuscle)

        let byEquipment = await coach.findHevyExercisesTool(query: nil, muscleGroup: "quadriceps",
                                                            equipment: "machine", limit: 15)
        XCTAssertTrue(byEquipment.contains("BBBB2222"), byEquipment)
        XCTAssertFalse(byEquipment.contains("AAAA1111"), byEquipment)
    }

    /// A secondary muscle counts as a match: someone asking for triceps work should be offered the
    /// press that trains them, not only isolation movements.
    func testTheSearchMatchesSecondaryMuscles() async throws {
        let (coach, _) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        let out = await coach.findHevyExercisesTool(query: nil, muscleGroup: "triceps",
                                                    equipment: nil, limit: 15)
        XCTAssertTrue(out.contains("05293BCA"), out)
    }

    /// No match tells the model what to do next, and explicitly not to invent an id — the failure mode
    /// this whole tool exists to prevent.
    func testAnEmptySearchTellsTheModelNotToInventAnId() async throws {
        let (coach, _) = try await engine { store in
            try await store.upsertHevyExerciseTemplates(self.catalogue)
        }
        let out = await coach.findHevyExercisesTool(query: "kettlebell juggling", muscleGroup: nil,
                                                    equipment: nil, limit: 15)
        XCTAssertTrue(out.contains("Do NOT invent"), out)
    }

    /// With nothing synced the search says so rather than returning an empty list the model might read
    /// as "this user has no chest exercises".
    func testAnUnsyncedCatalogueIsReportedAsUnsynced() async throws {
        let (coach, _) = try await engine()
        let out = await coach.findHevyExercisesTool(query: "bench", muscleGroup: nil,
                                                    equipment: nil, limit: 15)
        XCTAssertTrue(out.contains("must not invent"), out)
    }
}
