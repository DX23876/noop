import Foundation
import WhoopStore

// MARK: - Hevy public API v1 document parser (PURE / network-free)
//
// Takes already-fetched JSON documents (the app-target `HevyAPIClient` does the I/O) and maps them to
// the `WhoopStore` value types. Same shape as `OuraApiParser`: dictionaries in, domain values out, so
// the mapping is testable on Linux with no network, no strap and no database.
//
// TOLERANT BY DESIGN, and not merely as house style. Hevy's own API documentation says: "we make no
// guarantees that we won't completely change the structure or abandon the project entirely." A strict
// decode would turn a renamed field into a sync that fails wholesale — the worst possible failure for
// a background job, because the user sees stale data with no obvious cause. So every parse skips what
// it cannot read, COUNTS the skip, and returns what it could. `HevyParseResult.skipped` is surfaced in
// Data Sources, which is what keeps "tolerant" from becoming "silent".

/// What a parse produced, plus how much it had to drop. The count is reported to the user rather than
/// swallowed — a sync that quietly discarded half a workout would be worse than one that failed.
public struct HevyParseResult<T: Sendable>: Sendable {
    public var items: [T]
    /// Documents (or nested sets) dropped: no id, no usable timestamp, or nothing measurable in them.
    public var skipped: Int

    public init(items: [T], skipped: Int) {
        self.items = items
        self.skipped = skipped
    }
}

public enum HevyApiParser {

    // MARK: - Workouts

    /// Parse `data.workouts[]` (or the `workout` object inside an event) into full sessions.
    public static func parseWorkouts(_ docs: [[String: Any]]) -> HevyParseResult<HevyWorkout> {
        var out: [HevyWorkout] = []
        var skipped = 0
        for doc in docs {
            if let w = parseWorkout(doc, skipped: &skipped) { out.append(w) } else { skipped += 1 }
        }
        return HevyParseResult(items: out, skipped: skipped)
    }

    /// One workout, or nil when it carries no id or no readable start. `skipped` accumulates dropped
    /// SETS from inside it — a session with one unreadable set is still a session.
    static func parseWorkout(_ doc: [String: Any], skipped: inout Int) -> HevyWorkout? {
        guard let id = WearableJSON.str(doc, "id"), !id.isEmpty,
              let start = isoSeconds(doc, "start_time") else { return nil }

        // A missing or earlier end is treated as "no measurable duration" rather than as corruption:
        // the sets are the data that matters, and they are all still there. `HevyWorkout.durationS`
        // then honestly returns nil instead of a negative number.
        let end = max(isoSeconds(doc, "end_time") ?? start, start)
        // The cursor depends on `updated_at`. Falling back through `created_at` to the start keeps a
        // document with a missing field from parking the cursor at zero, where every later run would
        // re-fetch the whole history.
        let updated = isoSeconds(doc, "updated_at") ?? isoSeconds(doc, "created_at") ?? start
        let created = isoSeconds(doc, "created_at") ?? start

        var exercises: [HevyExercise] = []
        for (fallbackIndex, raw) in ((doc["exercises"] as? [Any]) ?? []).enumerated() {
            guard let e = raw as? [String: Any] else { skipped += 1; continue }
            exercises.append(parseExercise(e, fallbackIndex: fallbackIndex, skipped: &skipped))
        }

        return HevyWorkout(
            id: id,
            title: WearableJSON.str(doc, "title") ?? "",
            routineId: WearableJSON.str(doc, "routine_id"),
            // Hevy names this `description`; the model calls it `notes` because `description` collides
            // with `CustomStringConvertible` on every Swift type.
            notes: WearableJSON.str(doc, "description"),
            startTs: start, endTs: end,
            updatedAtTs: updated, createdAtTs: created,
            exercises: exercises)
    }

    /// One exercise. Never nil: an exercise with an unreadable title or no sets still occupies its
    /// place in the session, and dropping it would silently renumber everything after it.
    static func parseExercise(_ doc: [String: Any], fallbackIndex: Int,
                              skipped: inout Int) -> HevyExercise {
        var sets: [HevySet] = []
        for (fallback, raw) in ((doc["sets"] as? [Any]) ?? []).enumerated() {
            guard let s = raw as? [String: Any] else { skipped += 1; continue }
            if let set = parseSet(s, fallbackIndex: fallback) { sets.append(set) } else { skipped += 1 }
        }
        return HevyExercise(
            index: WearableJSON.int(doc, "index") ?? fallbackIndex,
            title: WearableJSON.str(doc, "title") ?? "",
            templateId: WearableJSON.str(doc, "exercise_template_id"),
            supersetId: WearableJSON.int(doc, "superset_id"),
            notes: WearableJSON.str(doc, "notes"),
            sets: sets)
    }

    /// One set, or nil when it measures NOTHING — no weight, reps, distance, duration or custom
    /// metric. Such a row cannot contribute to any figure the app derives, and keeping it would
    /// inflate the set counts that weekly volume is built from.
    ///
    /// Note what is deliberately NOT a reason to skip: a set with reps but no weight is a bodyweight
    /// set and entirely real; a set with no RPE simply was not rated.
    static func parseSet(_ doc: [String: Any], fallbackIndex: Int) -> HevySet? {
        let weight = WearableJSON.posDbl(doc, "weight_kg")
        let reps = WearableJSON.posInt(doc, "reps")
        let distance = WearableJSON.posDbl(doc, "distance_meters")
        let duration = WearableJSON.posDbl(doc, "duration_seconds")
        let custom = WearableJSON.dbl(doc, "custom_metric")
        guard weight != nil || reps != nil || distance != nil || duration != nil || custom != nil else {
            return nil
        }
        return HevySet(
            index: WearableJSON.int(doc, "index") ?? fallbackIndex,
            type: HevySetType.parse(WearableJSON.str(doc, "type")),
            weightKg: weight, reps: reps, distanceM: distance, durationS: duration,
            // RPE is bounded rather than trusted: Hevy's scale runs 6–10 in half steps, so a value
            // outside 1...10 is a unit mix-up or corruption, and an out-of-range "RPE" would poison
            // every effort-vs-load comparison that reads it.
            rpe: WearableJSON.dbl(doc, "rpe").flatMap { $0 >= 1 && $0 <= 10 ? $0 : nil },
            customMetric: custom)
    }

    // MARK: - The incremental feed

    /// Parse `events[]` from `GET /v1/workouts/events?since=`.
    ///
    /// Deletes are as important as updates: a workout removed in Hevy has to disappear here too, or
    /// the app keeps showing a session that no longer exists and keeps scoring its day around it.
    public static func parseWorkoutEvents(_ docs: [[String: Any]]) -> HevyParseResult<HevyWorkoutEvent> {
        var out: [HevyWorkoutEvent] = []
        var skipped = 0
        for doc in docs {
            switch WearableJSON.str(doc, "type")?.lowercased() {
            case "updated":
                guard let payload = doc["workout"] as? [String: Any],
                      let w = parseWorkout(payload, skipped: &skipped) else { skipped += 1; continue }
                out.append(.updated(w))
            case "deleted":
                guard let id = WearableJSON.str(doc, "id"), !id.isEmpty else { skipped += 1; continue }
                // A delete with no readable timestamp still has to be APPLIED — the workout is gone
                // either way. It contributes 0 to the cursor, which only means it cannot advance it.
                out.append(.deleted(id: id, atTs: isoSeconds(doc, "deleted_at") ?? 0))
            default:
                // An event type this build does not know. Counted, never guessed at: applying an
                // unknown verb to a user's training history is exactly the wrong kind of confident.
                skipped += 1
            }
        }
        return HevyParseResult(items: out, skipped: skipped)
    }

    // MARK: - The exercise catalogue

    public static func parseExerciseTemplates(_ docs: [[String: Any]])
        -> HevyParseResult<HevyExerciseTemplate> {
        var out: [HevyExerciseTemplate] = []
        var skipped = 0
        for doc in docs {
            guard let id = WearableJSON.str(doc, "id"), !id.isEmpty,
                  let title = WearableJSON.str(doc, "title"), !title.isEmpty else {
                skipped += 1
                continue
            }
            let secondary = ((doc["secondary_muscle_groups"] as? [Any]) ?? [])
                .compactMap { $0 as? String }
                .map { HevyMuscleGroup.parse($0) }
            out.append(HevyExerciseTemplate(
                id: id, title: title,
                type: WearableJSON.str(doc, "type") ?? "",
                primaryMuscleGroup: HevyMuscleGroup.parse(WearableJSON.str(doc, "primary_muscle_group")),
                secondaryMuscleGroups: secondary,
                equipment: HevyEquipment.parse(WearableJSON.str(doc, "equipment")),
                isCustom: (doc["is_custom"] as? Bool) ?? false))
        }
        return HevyParseResult(items: out, skipped: skipped)
    }

    // MARK: - Routines

    /// Parse saved routines, keeping each one's document verbatim.
    ///
    /// `rawJSON` is re-serialised from the parsed dictionary rather than sliced out of the response
    /// bytes: the caller hands us documents, not offsets. It is a faithful round trip of everything
    /// the server sent, which is what `PUT /v1/routines/{id}` needs — that endpoint is a FULL REPLACE,
    /// so any field this build does not model would be dropped on the first edit without it.
    public static func parseRoutines(_ docs: [[String: Any]]) -> HevyParseResult<HevyRoutine> {
        var out: [HevyRoutine] = []
        var skipped = 0
        for doc in docs {
            guard let id = WearableJSON.str(doc, "id"), !id.isEmpty else { skipped += 1; continue }
            var setSkips = 0
            var exercises: [HevyExercise] = []
            for (fallbackIndex, raw) in ((doc["exercises"] as? [Any]) ?? []).enumerated() {
                guard let e = raw as? [String: Any] else { setSkips += 1; continue }
                exercises.append(parseExercise(e, fallbackIndex: fallbackIndex, skipped: &setSkips))
            }
            skipped += setSkips
            let raw = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            out.append(HevyRoutine(
                id: id,
                title: WearableJSON.str(doc, "title") ?? "",
                folderId: WearableJSON.int(doc, "folder_id"),
                notes: WearableJSON.str(doc, "notes"),
                updatedAtTs: isoSeconds(doc, "updated_at") ?? 0,
                exercises: exercises,
                rawJSON: raw))
        }
        return HevyParseResult(items: out, skipped: skipped)
    }

    // MARK: - Helpers

    /// An ISO-8601 field as unix seconds. Hevy sends `2021-09-14T12:00:00Z`; the shared parser also
    /// accepts an explicit offset and fractional seconds, so a future format tweak in either direction
    /// keeps working.
    private static func isoSeconds(_ doc: [String: Any], _ key: String) -> Int? {
        guard let d = WhoopTime.parseISOWithOffset(WearableJSON.str(doc, key)) else { return nil }
        return Int(d.timeIntervalSince1970)
    }

    // MARK: - Envelope unwrapping

    /// The array under `key` in a Hevy response envelope (`{"workouts": [...]}`, `{"events": [...]}`,
    /// `{"exercise_templates": [...]}`), or empty. Kept here rather than in the client so the whole
    /// response shape is covered by tests that need no network.
    public static func objects(_ data: Data, key: String) -> [[String: Any]] {
        guard let root = WearableJSON.object(data) else { return [] }
        return (root[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// `page_count` from a paginated envelope, defaulting to 1 so a malformed envelope stops paging
    /// rather than looping.
    public static func pageCount(_ data: Data) -> Int {
        guard let root = WearableJSON.object(data) else { return 1 }
        return max(1, WearableJSON.int(root, "page_count") ?? 1)
    }
}
