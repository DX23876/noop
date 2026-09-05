import Foundation
import WhoopStore
import StrandImport

/// The ONE place in the program that writes to Hevy.
///
/// It takes a proposal the user has explicitly confirmed and nothing else. There is no path from a
/// model reply to this type: the coach's tool creates a `HevyRoutineProposal`, the review screen shows
/// it in full, and only the button in that screen calls `send`.
///
/// ## What a `PUT` to Hevy actually does, and what that means here
///
/// `PUT /v1/routines/{id}` is a **full replace**. The body's `exercises` array becomes the routine —
/// anything not in it is gone. There is no partial update, and no merge this code could perform would
/// change that: the exercise list the coach drafted IS the new routine.
///
/// So the protection is not clever merging, it is **a visible diff and an explicit yes**. The review
/// screen shows the routine as it stands beside the routine as it would become, so a draft that would
/// drop four exercises looks like one before it is sent, not after. `HevyRoutineProposal.previousRawJSON`
/// exists for that comparison and for restoring the previous version — not to smuggle unmodelled
/// fields through the write, which this deliberately does not attempt: sending fields the documented
/// request body does not list is a live experiment on somebody's training log.
enum HevyRoutineWriter {

    /// Send a confirmed proposal to Hevy. Returns the routine id the server assigned or updated.
    ///
    /// `fetcher` is injected so the whole path is testable without a network; the app passes
    /// `HevyAPIClient`.
    static func send(_ proposal: HevyRoutineProposal,
                     using fetcher: HevyFetching) async throws -> String {
        let body = try requestBody(for: proposal)
        switch proposal.operation {
        case .create:
            let data = try await fetcher.post(path: "/routines", body: body)
            return routineId(from: data) ?? ""
        case .update:
            guard let id = proposal.routineId, !id.isEmpty else { throw HevyError.decode }
            _ = try await fetcher.put(path: "/routines/\(id)", body: body)
            return id
        }
    }

    /// The request body, built to Hevy's documented shape.
    ///
    /// Pure and `internal` so a test can assert on the exact JSON. What goes over the wire to a user's
    /// account is worth pinning byte for byte rather than inferring from a passing integration.
    static func requestBody(for proposal: HevyRoutineProposal) throws -> Data {
        var routine: [String: Any] = [
            "title": proposal.title,
            "exercises": proposal.exercises.map(exerciseJSON),
        ]
        // `folder_id` is nullable and means "My Routines" when null, so it is only sent when the draft
        // actually names a folder — an explicit null would be a claim the coach never made.
        if let folderId = proposal.folderId { routine["folder_id"] = folderId }
        if let notes = proposal.notes, !notes.isEmpty { routine["notes"] = notes }
        return try JSONSerialization.data(withJSONObject: ["routine": routine],
                                          options: [.sortedKeys])
    }

    private static func exerciseJSON(_ exercise: HevyRoutineDraftExercise) -> [String: Any] {
        var out: [String: Any] = [
            "exercise_template_id": exercise.templateId,
            "sets": exercise.sets.map(setJSON),
        ]
        if let supersetId = exercise.supersetId { out["superset_id"] = supersetId }
        if let rest = exercise.restSeconds { out["rest_seconds"] = rest }
        if let notes = exercise.notes, !notes.isEmpty { out["notes"] = notes }
        return out
    }

    private static func setJSON(_ set: HevyRoutineDraftSet) -> [String: Any] {
        var out: [String: Any] = ["type": set.type == .other ? "normal" : set.type.rawValue]
        if let weight = set.weightKg, weight > 0 { out["weight_kg"] = weight }
        if let reps = set.reps { out["reps"] = reps }
        // A rep RANGE is how programmes are actually written, and Hevy stores it natively — so a range
        // stays a range rather than collapsing to a single number the user never chose.
        if let start = set.repRangeStart, let end = set.repRangeEnd, end >= start {
            out["rep_range"] = ["start": start, "end": end]
        }
        return out
    }

    private static func routineId(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // The create response wraps the routine; some versions return it bare. Both are read rather
        // than assuming one, because an id we fail to record is a routine we can never update again.
        if let routine = root["routine"] as? [String: Any], let id = routine["id"] as? String { return id }
        if let id = root["id"] as? String { return id }
        if let list = root["routines"] as? [[String: Any]], let id = list.first?["id"] as? String {
            return id
        }
        return nil
    }
}
