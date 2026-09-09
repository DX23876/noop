import XCTest
import WhoopStore
@testable import Strand

/// Pins the boundary between "the coach designed a routine" and "the routine is in the user's Hevy
/// account" — the two things this feature keeps apart.
///
/// The tests fall into three groups, and each guards a different way the boundary could quietly fail:
/// a draft that names an exercise nobody has (an id the model made up), a draft that is treated as
/// already-decided (a payload pre-accepting itself), and a write that sends something other than what
/// the user saw.
/// `@MainActor` because `HevyRoutineProposalStore` is — the inbox is UI-facing state, and the store
/// enforces that at the type level rather than trusting call sites.
@MainActor
final class HevyRoutineProposalTests: XCTestCase {

    private func store() -> HevyRoutineProposalStore {
        // A private defaults suite, so a test can never read or clobber the real inbox.
        let defaults = UserDefaults(suiteName: "hevy.routine.tests.\(UUID().uuidString)")!
        return HevyRoutineProposalStore(defaults: defaults, storageKey: "test", loading: false)
    }

    private func draft(_ exercises: [HevyRoutineDraftExercise] = [
        HevyRoutineDraftExercise(templateId: "T1", title: "Bench Press (Barbell)",
                                 sets: [HevyRoutineDraftSet(type: .normal, weightKg: 80, reps: 8)]),
    ], operation: HevyRoutineProposal.Operation = .create) -> HevyRoutineProposal {
        HevyRoutineProposal(operation: operation, routineId: operation == .update ? "r1" : nil,
                            title: "Push Day", exercises: exercises, rationale: "Because.")
    }

    // MARK: - The inbox

    /// A draft starts, and stays, `.proposed`. A payload that arrived pre-accepted — from a malformed
    /// tool call or a provider-authored response — must not be able to skip the review.
    func testAProposalCannotPreAcceptItself() {
        let inbox = store()
        var sneaky = draft()
        sneaky.status = .sent
        sneaky.decidedAt = Date()
        inbox.propose(sneaky)

        XCTAssertEqual(inbox.proposals.first?.status, .proposed)
        XCTAssertNil(inbox.proposals.first?.decidedAt)
    }

    func testAnEmptyDraftIsRejected() {
        let inbox = store()
        XCTAssertFalse(inbox.propose(draft([])))
        XCTAssertTrue(inbox.proposals.isEmpty)
    }

    /// A failed send stays visible with its error, rather than reverting to an undecided draft: the
    /// difference is whether the user is offered a retry or the same draft silently reappears as though
    /// nothing had been attempted.
    func testAFailedSendStaysPendingWithItsReason() {
        let inbox = store()
        let proposal = draft()
        inbox.propose(proposal)
        let id = inbox.proposals[0].id
        inbox.decide(id, as: .failed, error: "Hevy rejected the API key.")

        XCTAssertEqual(inbox.proposal(id: id)?.status, .failed)
        XCTAssertEqual(inbox.proposal(id: id)?.lastError, "Hevy rejected the API key.")
        XCTAssertEqual(inbox.pending.count, 1, "a failed send is still waiting on the user")
    }

    func testASentDraftLeavesThePendingList() {
        let inbox = store()
        inbox.propose(draft())
        inbox.decide(inbox.proposals[0].id, as: .sent)
        XCTAssertTrue(inbox.pending.isEmpty)
    }

    /// Working sets, not all sets: a routine's volume is not judged on its warmups.
    func testWorkingSetsExcludeWarmups() {
        let proposal = draft([
            HevyRoutineDraftExercise(templateId: "T1", title: "Bench", sets: [
                HevyRoutineDraftSet(type: .warmup, weightKg: 40, reps: 10),
                HevyRoutineDraftSet(type: .normal, weightKg: 80, reps: 8),
                HevyRoutineDraftSet(type: .failure, weightKg: 80, reps: 6),
            ]),
        ])
        XCTAssertEqual(proposal.totalSets, 3)
        XCTAssertEqual(proposal.totalWorkingSets, 2)
    }

    // MARK: - The request body

    /// What actually goes over the wire to somebody's training log, pinned exactly. Inferring this
    /// from a passing integration test would leave the one field that matters unchecked.
    func testTheCreateBodyMatchesHevysDocumentedShape() throws {
        let proposal = HevyRoutineProposal(
            operation: .create, title: "Push Day", notes: "Form first", folderId: 42,
            exercises: [
                HevyRoutineDraftExercise(templateId: "05293BCA", title: "Bench", supersetId: 0,
                                         restSeconds: 90, notes: "slow eccentric",
                                         sets: [
                                            HevyRoutineDraftSet(type: .warmup, weightKg: 40, reps: 10),
                                            HevyRoutineDraftSet(type: .normal, repRangeStart: 8,
                                                                repRangeEnd: 12),
                                         ]),
            ],
            rationale: "")

        let data = try HevyRoutineWriter.requestBody(for: proposal)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routine = try XCTUnwrap(root["routine"] as? [String: Any])
        XCTAssertEqual(routine["title"] as? String, "Push Day")
        XCTAssertEqual(routine["folder_id"] as? Int, 42)
        XCTAssertEqual(routine["notes"] as? String, "Form first")

        let exercises = try XCTUnwrap(routine["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.count, 1)
        XCTAssertEqual(exercises[0]["exercise_template_id"] as? String, "05293BCA")
        XCTAssertEqual(exercises[0]["rest_seconds"] as? Int, 90)
        XCTAssertEqual(exercises[0]["superset_id"] as? Int, 0)

        let sets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])
        XCTAssertEqual(sets[0]["type"] as? String, "warmup")
        XCTAssertEqual(sets[0]["weight_kg"] as? Double, 40)
        // A prescribed RANGE stays a range. Collapsing "8–12" to 10 would put a number in front of the
        // user that neither they nor the coach chose.
        let range = try XCTUnwrap(sets[1]["rep_range"] as? [String: Any])
        XCTAssertEqual(range["start"] as? Int, 8)
        XCTAssertEqual(range["end"] as? Int, 12)
        XCTAssertNil(sets[1]["reps"], "a range is not also a fixed rep count")
    }

    /// `folder_id` is nullable and means "My Routines" when absent, so it is sent only when the draft
    /// names a folder. An explicit null would be a claim the coach never made.
    func testAnAbsentFolderIsOmittedRatherThanSentAsNull() throws {
        let data = try HevyRoutineWriter.requestBody(for: draft())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routine = try XCTUnwrap(root["routine"] as? [String: Any])
        XCTAssertNil(routine["folder_id"])
        XCTAssertNil(routine["notes"])
    }

    /// An unrecognised set type is written as `normal` rather than passed through: Hevy's own enum has
    /// four values, and sending a fifth would be rejected for the whole routine.
    func testAnUnknownSetTypeIsNormalisedForTheWire() throws {
        let proposal = draft([
            HevyRoutineDraftExercise(templateId: "T1", title: "Bench",
                                     sets: [HevyRoutineDraftSet(type: .other, weightKg: 80, reps: 8)]),
        ])
        let data = try HevyRoutineWriter.requestBody(for: proposal)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routine = try XCTUnwrap(root["routine"] as? [String: Any])
        let exercises = try XCTUnwrap(routine["exercises"] as? [[String: Any]])
        let sets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])
        XCTAssertEqual(sets[0]["type"] as? String, "normal")
    }

    /// A zero or absent weight is omitted, not sent as 0 — a bodyweight set prescribed as "0 kg" reads
    /// as an error in the Hevy app.
    func testAZeroWeightIsOmitted() throws {
        let proposal = draft([
            HevyRoutineDraftExercise(templateId: "T1", title: "Pull Up",
                                     sets: [HevyRoutineDraftSet(type: .normal, weightKg: 0, reps: 10)]),
        ])
        let data = try HevyRoutineWriter.requestBody(for: proposal)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let routine = try XCTUnwrap(root["routine"] as? [String: Any])
        let exercises = try XCTUnwrap(routine["exercises"] as? [[String: Any]])
        let sets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])
        XCTAssertNil(sets[0]["weight_kg"])
        XCTAssertEqual(sets[0]["reps"] as? Int, 10)
    }
}

@MainActor
final class HevyWorkoutProposalTests: XCTestCase {
    private func workout(id: String = "pending-1") -> HevyWorkout {
        HevyWorkout(
            id: id, title: "Push day", routineId: nil, notes: "Good form",
            startTs: 1_700_000_000, endTs: 1_700_003_600,
            updatedAtTs: 1_700_003_600, createdAtTs: 1_700_000_000,
            exercises: [
                HevyExercise(index: 0, title: "Bench Press", templateId: "bench-1",
                             supersetId: nil, notes: nil,
                             sets: [
                                HevySet(index: 0, type: .warmup, weightKg: 40, reps: 10,
                                        distanceM: nil, durationS: nil, rpe: nil, customMetric: nil),
                                HevySet(index: 1, type: .normal, weightKg: 80, reps: 8,
                                        distanceM: nil, durationS: nil, rpe: 8, customMetric: nil),
                             ])
            ])
    }

    func testWorkoutProposalCannotPreAcceptItself() {
        let defaults = UserDefaults(suiteName: "hevy.workout.tests.\(UUID().uuidString)")!
        let inbox = HevyWorkoutProposalStore(defaults: defaults, storageKey: "test", loading: false)
        var proposal = HevyWorkoutProposal(operation: .create, workout: workout(), rationale: "Progress")
        proposal.status = .sent

        XCTAssertTrue(inbox.propose(proposal))
        XCTAssertEqual(inbox.pending.first?.status, .proposed)
    }

    func testCompletedWorkoutBodyPreservesReviewedSets() throws {
        let data = try HevyWorkoutWriter.requestBody(for: workout())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try XCTUnwrap(root["workout"] as? [String: Any])
        XCTAssertEqual(body["title"] as? String, "Push day")
        XCTAssertEqual(body["description"] as? String, "Good form")
        let exercises = try XCTUnwrap(body["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.first?["exercise_template_id"] as? String, "bench-1")
        let sets = try XCTUnwrap(exercises.first?["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets[0]["type"] as? String, "warmup")
        XCTAssertEqual(sets[1]["weight_kg"] as? Double, 80)
        XCTAssertEqual(sets[1]["reps"] as? Int, 8)
        XCTAssertEqual(sets[1]["rpe"] as? Double, 8)
    }
}
