import Foundation
import GRDB

// MARK: - v54 Hevy strength store
//
// Persistence for the Hevy lane. Follows the established pattern exactly — value types in
// `HevyModels.swift`, idempotent `ON CONFLICT` upserts keyed by Hevy's own ids, range reads, all GRDB
// work through the actor's `syncWrite` / `syncRead`.
//
// IDEMPOTENCE IS THE POINT. Hevy's incremental feed can re-deliver a workout the store already has
// (a re-run after a failure, a workout edited twice, a page boundary re-fetched). Every write here
// has to converge on the same rows rather than accumulate. Upserting the parent is not enough for
// that: a workout edited to REMOVE an exercise would otherwise keep the removed rows, so the child
// rows are deleted and rewritten as one transaction. That is also why `hevyExercise` / `hevySet`
// declare `ON DELETE CASCADE` — the parent delete cannot forget them.

extension WhoopStore {

    // MARK: - Writes

    /// Upsert full workouts (parent + exercises + sets) in ONE transaction each.
    ///
    /// Returns the affected UTC day timestamps — the caller passes them to
    /// `markAnalysisInputsChanged` so only the days that actually moved are re-derived. Returning
    /// them rather than marking here keeps this layer free of the analysis contract, and lets an
    /// importer batch one revision bump for a whole sync.
    @discardableResult
    public func upsertHevyWorkouts(_ workouts: [HevyWorkout]) async throws -> [Int] {
        try await upsertStrengthWorkouts(workouts.map {
            HevyWorkout(id: $0.id, title: $0.title, routineId: $0.routineId, notes: $0.notes,
                        startTs: $0.startTs, endTs: $0.endTs, updatedAtTs: $0.updatedAtTs,
                        createdAtTs: $0.createdAtTs, exercises: $0.exercises, source: .hevyAPI)
        })
    }

    /// Upsert complete sessions from any strength source. File-import ids must be deterministic.
    @discardableResult
    public func upsertStrengthWorkouts(_ workouts: [HevyWorkout]) async throws -> [Int] {
        guard !workouts.isEmpty else { return [] }
        return try syncWrite { db in
            var touched: [Int] = []
            for w in workouts {
                try db.execute(sql: """
                    INSERT INTO hevyWorkout
                        (id, title, routineId, notes, startTs, endTs, updatedAtTs, createdAtTs, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title, routineId = excluded.routineId, notes = excluded.notes,
                        startTs = excluded.startTs, endTs = excluded.endTs,
                        updatedAtTs = excluded.updatedAtTs, createdAtTs = excluded.createdAtTs,
                        source = excluded.source
                    """, arguments: [w.id, w.title, w.routineId, w.notes,
                                     w.startTs, w.endTs, w.updatedAtTs, w.createdAtTs,
                                     w.source.rawValue])

                // Rewrite the children wholesale. An edit that DROPS an exercise or a set has no
                // upsert that would remove the stale row, and a leftover set would keep counting
                // toward weekly volume forever.
                try db.execute(sql: "DELETE FROM hevyExercise WHERE workoutId = ?", arguments: [w.id])
                try db.execute(sql: "DELETE FROM hevySet WHERE workoutId = ?", arguments: [w.id])

                for e in w.exercises {
                    try db.execute(sql: """
                        INSERT INTO hevyExercise (workoutId, idx, title, templateId, supersetId, notes)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [w.id, e.index, e.title, e.templateId, e.supersetId, e.notes])
                    for s in e.sets {
                        try db.execute(sql: """
                            INSERT INTO hevySet
                                (workoutId, exerciseIdx, idx, type, weightKg, reps,
                                 distanceM, durationS, rpe, customMetric)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [w.id, e.index, s.index, s.type.rawValue,
                                             s.weightKg, s.reps, s.distanceM, s.durationS,
                                             s.rpe, s.customMetric])
                    }
                }
                touched.append(w.startTs)
            }
            return touched
        }
    }

    /// Delete workouts by Hevy id (a `deleted` event). Exercises and sets go with them by cascade.
    ///
    /// Returns the `startTs` of every row that actually existed, so the caller can invalidate exactly
    /// those days. A delete for an id we never had returns nothing and marks nothing — deleting what
    /// was never there is not a change.
    @discardableResult
    public func deleteHevyWorkouts(ids: [String]) async throws -> [Int] {
        guard !ids.isEmpty else { return [] }
        return try syncWrite { db in
            var touched: [Int] = []
            for id in ids {
                if let ts = try Int.fetchOne(db, sql: "SELECT startTs FROM hevyWorkout WHERE id = ?",
                                             arguments: [id]) {
                    touched.append(ts)
                }
                try db.execute(sql: "DELETE FROM hevyWorkout WHERE id = ?", arguments: [id])
            }
            return touched
        }
    }

    /// Upsert exercise-catalogue entries. The catalogue is mirrored in full and refreshed wholesale;
    /// entries are never deleted here, because an exercise removed from Hevy's catalogue may still be
    /// referenced by a workout already in the history — and a history row that cannot name its muscle
    /// group is worse than a stale catalogue entry.
    @discardableResult
    public func upsertHevyExerciseTemplates(_ templates: [HevyExerciseTemplate]) async throws -> Int {
        guard !templates.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for t in templates {
                let secondary = t.secondaryMuscleGroups.map(\.rawValue)
                let json = (try? JSONEncoder().encode(secondary))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(sql: """
                    INSERT INTO hevyExerciseTemplate
                        (id, title, type, primaryMuscleGroup, secondaryMuscleGroupsJSON, equipment, isCustom)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title, type = excluded.type,
                        primaryMuscleGroup = excluded.primaryMuscleGroup,
                        secondaryMuscleGroupsJSON = excluded.secondaryMuscleGroupsJSON,
                        equipment = excluded.equipment, isCustom = excluded.isCustom
                    """, arguments: [t.id, t.title, t.type, t.primaryMuscleGroup.rawValue,
                                     json, t.equipment.rawValue, t.isCustom])
                n += db.changesCount
            }
            return n
        }
    }

    /// Upsert saved routines, keeping each one's verbatim server document.
    @discardableResult
    public func upsertHevyRoutines(_ routines: [HevyRoutine]) async throws -> Int {
        guard !routines.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in routines {
                try db.execute(sql: """
                    INSERT INTO hevyRoutine (id, title, folderId, notes, updatedAtTs, rawJSON)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title, folderId = excluded.folderId, notes = excluded.notes,
                        updatedAtTs = excluded.updatedAtTs, rawJSON = excluded.rawJSON
                    """, arguments: [r.id, r.title, r.folderId, r.notes, r.updatedAtTs, r.rawJSON])
                n += db.changesCount
            }
            return n
        }
    }

    public func upsertStrengthExerciseMapping(_ mapping: StrengthExerciseMapping) async throws {
        let secondary = (try? JSONEncoder().encode(mapping.secondaryMuscleGroups.map(\.rawValue)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO strengthExerciseMapping
                    (normalizedTitle, displayTitle, primaryMuscleGroup, secondaryMuscleGroupsJSON, updatedAtTs)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(normalizedTitle) DO UPDATE SET
                    displayTitle = excluded.displayTitle,
                    primaryMuscleGroup = excluded.primaryMuscleGroup,
                    secondaryMuscleGroupsJSON = excluded.secondaryMuscleGroupsJSON,
                    updatedAtTs = excluded.updatedAtTs
                """, arguments: [mapping.normalizedTitle, mapping.displayTitle,
                                   mapping.primaryMuscleGroup.rawValue, secondary,
                                   Int(Date().timeIntervalSince1970)])
        }
    }

    public func strengthExerciseMappings() async throws -> [String: StrengthExerciseMapping] {
        return try syncRead { db in
            var result: [String: StrengthExerciseMapping] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT normalizedTitle, displayTitle, primaryMuscleGroup, secondaryMuscleGroupsJSON
                FROM strengthExerciseMapping
                """) {
                let key: String = row["normalizedTitle"]
                let raw: String = row["secondaryMuscleGroupsJSON"]
                let secondary = ((try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? [])
                    .map(HevyMuscleGroup.parse)
                result[key] = StrengthExerciseMapping(
                    normalizedTitle: key, displayTitle: row["displayTitle"],
                    primaryMuscleGroup: HevyMuscleGroup.parse(row["primaryMuscleGroup"]),
                    secondaryMuscleGroups: secondary)
            }
            return result
        }
    }

    // MARK: - Reads

    /// Full workouts (with exercises and sets) whose START falls in [from, to], newest first.
    ///
    /// Reads the three tables with three queries and assembles in memory rather than one join per
    /// workout: a month of training is a few hundred sets, and the per-workout query shape is exactly
    /// the N+1 that made `workoutRows`' HR reconcile a launch-freeze suspect.
    public func hevyWorkouts(from: Int, to: Int, limit: Int = 2000) async throws -> [HevyWorkout] {
        try await strengthWorkouts(from: from, to: to, limit: limit, sources: [.hevyAPI])
    }

    /// Complete strength history across API and offline imports. Exact duplicate sessions are
    /// collapsed for analysis, preferring API data and then the record with more set detail.
    public func strengthWorkouts(from: Int, to: Int, limit: Int = 2000,
                                 sources: Set<StrengthDataSource> = Set(StrengthDataSource.allCases)) async throws -> [HevyWorkout] {
        guard !sources.isEmpty else { return [] }
        return try syncRead { db in
            let sourceValues = sources.map(\.rawValue).sorted()
            let sourceMarks = databaseQuestionMarks(count: sourceValues.count)
            var arguments: [DatabaseValueConvertible?] = [from, to]
            arguments.append(contentsOf: sourceValues)
            arguments.append(limit)
            let heads = try Row.fetchAll(db, sql: """
                SELECT id, title, routineId, notes, startTs, endTs, updatedAtTs, createdAtTs, source
                FROM hevyWorkout
                WHERE startTs >= ? AND startTs <= ? AND source IN (\(sourceMarks))
                ORDER BY startTs DESC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            guard !heads.isEmpty else { return [] }
            let ids = heads.map { $0["id"] as String }
            let placeholders = databaseQuestionMarks(count: ids.count)

            var setsByExercise: [String: [Int: [HevySet]]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT workoutId, exerciseIdx, idx, type, weightKg, reps,
                       distanceM, durationS, rpe, customMetric
                FROM hevySet WHERE workoutId IN (\(placeholders))
                ORDER BY exerciseIdx ASC, idx ASC
                """, arguments: StatementArguments(ids)) {
                let wid: String = row["workoutId"]
                let eIdx: Int = row["exerciseIdx"]
                let set = HevySet(index: row["idx"],
                                  type: HevySetType.parse(row["type"]),
                                  weightKg: row["weightKg"], reps: row["reps"],
                                  distanceM: row["distanceM"], durationS: row["durationS"],
                                  rpe: row["rpe"], customMetric: row["customMetric"])
                setsByExercise[wid, default: [:]][eIdx, default: []].append(set)
            }

            var mappings: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT normalizedTitle FROM strengthExerciseMapping") {
                let key: String = row["normalizedTitle"]
                mappings[key] = "local:\(key)"
            }
            var exercisesByWorkout: [String: [HevyExercise]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT workoutId, idx, title, templateId, supersetId, notes
                FROM hevyExercise WHERE workoutId IN (\(placeholders))
                ORDER BY idx ASC
                """, arguments: StatementArguments(ids)) {
                let wid: String = row["workoutId"]
                let idx: Int = row["idx"]
                exercisesByWorkout[wid, default: []].append(
                    HevyExercise(index: idx, title: row["title"],
                                 templateId: (row["templateId"] as String?) ?? mappings[strengthNormalizedTitle(row["title"])],
                                 supersetId: row["supersetId"], notes: row["notes"],
                                 sets: setsByExercise[wid]?[idx] ?? []))
            }

            let loaded = heads.map { row in
                let id: String = row["id"]
                return HevyWorkout(id: id, title: row["title"], routineId: row["routineId"],
                                   notes: row["notes"], startTs: row["startTs"], endTs: row["endTs"],
                                   updatedAtTs: row["updatedAtTs"], createdAtTs: row["createdAtTs"],
                                   exercises: exercisesByWorkout[id] ?? [],
                                   source: StrengthDataSource(rawValue: row["source"]) ?? .hevyAPI)
            }
            var bySession: [String: HevyWorkout] = [:]
            for workout in loaded {
                let key = "\(workout.startTs)|\(workout.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                if let old = bySession[key] {
                    let oldSets = old.exercises.reduce(0) { $0 + $1.sets.count }
                    let newSets = workout.exercises.reduce(0) { $0 + $1.sets.count }
                    if (workout.source == .hevyAPI && old.source != .hevyAPI) || newSets > oldSets {
                        bySession[key] = workout
                    }
                } else {
                    bySession[key] = workout
                }
            }
            return bySession.values.sorted { $0.startTs > $1.startTs }
        }
    }

    /// The newest `updated_at` the store has seen, or nil when nothing is stored yet.
    ///
    /// This IS the incremental cursor. Deriving it from the data rather than keeping a separate
    /// counter means a partially-completed sync cannot leave the cursor ahead of what was actually
    /// written — the failure mode where a run is interrupted and the next one skips the gap forever.
    public func hevyNewestUpdatedAt() async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT MAX(updatedAtTs) FROM hevyWorkout WHERE source = ?",
                             arguments: [StrengthDataSource.hevyAPI.rawValue])
        }
    }

    public func hevyWorkoutCount() async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hevyWorkout WHERE source = ?",
                             arguments: [StrengthDataSource.hevyAPI.rawValue]) ?? 0
        }
    }

    /// The whole exercise catalogue, by id. Small enough to hold in memory (a few hundred entries),
    /// and every consumer — muscle-group attribution, the coach's exercise search — wants it keyed.
    public func hevyExerciseTemplates() async throws -> [String: HevyExerciseTemplate] {
        try syncRead { db in
            var out: [String: HevyExerciseTemplate] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, title, type, primaryMuscleGroup, secondaryMuscleGroupsJSON, equipment, isCustom
                FROM hevyExerciseTemplate
                """) {
                let id: String = row["id"]
                let raw: String = row["secondaryMuscleGroupsJSON"]
                let secondary = ((try? JSONDecoder().decode([String].self,
                                                            from: Data(raw.utf8))) ?? [])
                    .map { HevyMuscleGroup.parse($0) }
                out[id] = HevyExerciseTemplate(
                    id: id, title: row["title"], type: row["type"],
                    primaryMuscleGroup: HevyMuscleGroup.parse(row["primaryMuscleGroup"]),
                    secondaryMuscleGroups: secondary,
                    equipment: HevyEquipment.parse(row["equipment"]),
                    isCustom: row["isCustom"])
            }
            return out
        }
    }

    /// API catalogue plus durable local mappings used by offline file imports.
    public func strengthExerciseTemplates() async throws -> [String: HevyExerciseTemplate] {
        var result = try await hevyExerciseTemplates()
        for mapping in try await strengthExerciseMappings().values {
            let id = "local:\(mapping.normalizedTitle)"
            result[id] = HevyExerciseTemplate(id: id, title: mapping.displayTitle,
                                               type: "weight_reps",
                                               primaryMuscleGroup: mapping.primaryMuscleGroup,
                                               secondaryMuscleGroups: mapping.secondaryMuscleGroups,
                                               equipment: .other, isCustom: true)
        }
        return result
    }

    /// Saved routines, newest edit first.
    ///
    /// **`exercises` comes back EMPTY.** A routine's contents live only inside `rawJSON`, and decoding
    /// that needs the API parser, which lives in `StrandImport` — a package that depends on this one, so
    /// it cannot be called from here. Callers that need the contents parse `rawJSON` themselves; the
    /// app layer does exactly that in `HevyRoutineTool`.
    ///
    /// This is stated rather than left to be discovered because an empty array reads as "this routine
    /// has no exercises", which is a different and much more plausible-looking claim.
    public func hevyRoutines() async throws -> [HevyRoutine] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, folderId, notes, updatedAtTs, rawJSON
                FROM hevyRoutine ORDER BY updatedAtTs DESC
                """).map {
                HevyRoutine(id: $0["id"], title: $0["title"], folderId: $0["folderId"],
                            notes: $0["notes"], updatedAtTs: $0["updatedAtTs"],
                            exercises: [], rawJSON: $0["rawJSON"])
            }
        }
    }

    /// Every trace of the Hevy lane, removed. Backs "disconnect and forget" in Data Sources: a user
    /// who revokes the integration should be able to leave nothing behind. The mirrored `WorkoutRow`s
    /// are the caller's to remove — they live in the shared workout table, not here.
    public func deleteAllHevyData() async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM hevyWorkout WHERE source = ?",
                           arguments: [StrengthDataSource.hevyAPI.rawValue])
            try db.execute(sql: "DELETE FROM hevyExerciseTemplate")
            try db.execute(sql: "DELETE FROM hevyRoutine")
        }
    }
}

/// `?, ?, ?` for an `IN` clause of `count` items. GRDB has no variadic binding for `IN`, and building
/// the list by string interpolation of the VALUES would be the injection this avoids.
private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
}

public func strengthNormalizedTitle(_ title: String) -> String {
    title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }.joined(separator: " ")
}
