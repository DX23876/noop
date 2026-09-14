import Foundation
import GRDB
import StrandTraining

extension WhoopStore {
    public func upsertTrainingExercises(_ exercises: [TrainingExercise], nowTs: Int) async throws {
        guard !exercises.isEmpty else { return }
        try syncWrite { db in
            for exercise in exercises {
                try db.execute(sql: """
                    INSERT INTO trainingExerciseDefinition
                      (id, title, mode, primaryMuscleId, secondaryMuscleIdsJSON, equipmentIdsJSON,
                       instructionsJSON, isUnilateral, source, sourceId, mediaId, updatedAtTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title, mode=excluded.mode, primaryMuscleId=excluded.primaryMuscleId,
                      secondaryMuscleIdsJSON=excluded.secondaryMuscleIdsJSON,
                      equipmentIdsJSON=excluded.equipmentIdsJSON,
                      instructionsJSON=excluded.instructionsJSON,
                      isUnilateral=excluded.isUnilateral, source=excluded.source,
                      sourceId=excluded.sourceId, mediaId=excluded.mediaId, updatedAtTs=excluded.updatedAtTs
                    """, arguments: [exercise.id, exercise.title, exercise.mode.rawValue,
                                      exercise.primaryMuscleId, try Self.json(exercise.secondaryMuscleIds),
                                      try Self.json(exercise.equipmentIds), try Self.json(exercise.instructions),
                                      exercise.isUnilateral, exercise.source.rawValue, exercise.sourceId,
                                      exercise.mediaId, nowTs])
            }
        }
    }

    public func trainingExercises() async throws -> [TrainingExercise] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trainingExerciseDefinition ORDER BY title COLLATE NOCASE")
                .map { row in
                    TrainingExercise(id: row["id"], title: row["title"],
                        mode: TrainingMeasurementMode(rawValue: row["mode"]) ?? .weightReps,
                        primaryMuscleId: row["primaryMuscleId"],
                        secondaryMuscleIds: try Self.decode([String].self, row["secondaryMuscleIdsJSON"]),
                        equipmentIds: try Self.decode([String].self, row["equipmentIdsJSON"]),
                        instructions: try Self.decode([String].self, row["instructionsJSON"]),
                        isUnilateral: row["isUnilateral"],
                        source: TrainingContentSource(rawValue: row["source"]) ?? .imported,
                        sourceId: row["sourceId"], mediaId: row["mediaId"])
                }
        }
    }

    public func upsertTrainingRoutine(_ routine: TrainingRoutine) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO trainingRoutineNative
                  (id, title, notes, defaultProgressionJSON, excludeFromProgression, createdAtTs, updatedAtTs)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, notes=excluded.notes,
                  defaultProgressionJSON=excluded.defaultProgressionJSON,
                  excludeFromProgression=excluded.excludeFromProgression, updatedAtTs=excluded.updatedAtTs
                """, arguments: [routine.id.uuidString, routine.title, routine.notes,
                                  try Self.json(routine.defaultProgression), routine.excludeFromProgression,
                                  routine.createdAt, routine.updatedAt])
            try db.execute(sql: "DELETE FROM trainingRoutineExercise WHERE routineId = ?",
                           arguments: [routine.id.uuidString])
            for (index, exercise) in routine.exercises.enumerated() {
                try db.execute(sql: """
                    INSERT INTO trainingRoutineExercise
                      (id, routineId, idx, exerciseId, restSeconds, supersetId, progressionJSON, barWeightKg, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [exercise.id.uuidString, routine.id.uuidString, index,
                                      exercise.exerciseId, exercise.restSeconds, exercise.supersetId?.uuidString,
                                      try exercise.progression.map(Self.json), exercise.barWeightKg, exercise.note])
                for (setIndex, set) in exercise.sets.enumerated() {
                    try db.execute(sql: """
                        INSERT INTO trainingRoutineSetPlan
                          (id, routineExerciseId, idx, phase, intensifier, targetWeightKg,
                           repsMin, repsMax, targetDurationS, targetDistanceM)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [set.id.uuidString, exercise.id.uuidString, setIndex,
                                          set.phase.rawValue, set.intensifier.rawValue, set.targetWeightKg,
                                          set.repsMin, set.repsMax, set.targetDurationS, set.targetDistanceM])
                }
            }
        }
    }

    public func trainingRoutines() async throws -> [TrainingRoutine] {
        try syncRead { db in
            let heads = try Row.fetchAll(db, sql: "SELECT * FROM trainingRoutineNative ORDER BY updatedAtTs DESC")
            let exerciseRows = try Row.fetchAll(db, sql: "SELECT * FROM trainingRoutineExercise ORDER BY routineId, idx")
            let setRows = try Row.fetchAll(db, sql: "SELECT * FROM trainingRoutineSetPlan ORDER BY routineExerciseId, idx")
            var sets: [String: [RoutineSetPlan]] = [:]
            for row in setRows {
                let owner: String = row["routineExerciseId"]
                guard let id = UUID(uuidString: row["id"]) else { continue }
                sets[owner, default: []].append(RoutineSetPlan(
                    id: id, phase: TrainingSetPhase(rawValue: row["phase"]) ?? .work,
                    intensifier: TrainingSetIntensifier(rawValue: row["intensifier"]) ?? .none,
                    targetWeightKg: row["targetWeightKg"], repsMin: row["repsMin"],
                    repsMax: row["repsMax"], targetDurationS: row["targetDurationS"],
                    targetDistanceM: row["targetDistanceM"]))
            }
            var exercises: [String: [RoutineExercise]] = [:]
            for row in exerciseRows {
                let owner: String = row["routineId"]
                let rawId: String = row["id"]
                guard let id = UUID(uuidString: rawId) else { continue }
                let progressionRaw: String? = row["progressionJSON"]
                exercises[owner, default: []].append(RoutineExercise(
                    id: id, exerciseId: row["exerciseId"], sets: sets[rawId] ?? [],
                    restSeconds: row["restSeconds"],
                    supersetId: (row["supersetId"] as String?).flatMap(UUID.init(uuidString:)),
                    progression: try progressionRaw.map { try Self.decode(ProgressionConfiguration.self, $0) },
                    barWeightKg: row["barWeightKg"], note: row["note"]))
            }
            return try heads.compactMap { row in
                let rawId: String = row["id"]
                guard let id = UUID(uuidString: rawId) else { return nil }
                return TrainingRoutine(id: id, title: row["title"], notes: row["notes"],
                    exercises: exercises[rawId] ?? [],
                    defaultProgression: try Self.decode(ProgressionConfiguration.self,
                                                        row["defaultProgressionJSON"]),
                    excludeFromProgression: row["excludeFromProgression"],
                    createdAt: row["createdAtTs"], updatedAt: row["updatedAtTs"])
            }
        }
    }

    public func deleteTrainingRoutine(id: UUID) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingRoutineNative WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func replaceTrainingSchedule(_ schedule: [TrainingWeekday: [UUID]]) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingSchedule")
            for weekday in TrainingWeekday.allCases {
                for (index, routineId) in (schedule[weekday] ?? []).enumerated() {
                    try db.execute(sql: "INSERT INTO trainingSchedule (weekday, idx, routineId) VALUES (?, ?, ?)",
                                   arguments: [weekday.rawValue, index, routineId.uuidString])
                }
            }
        }
    }

    public func replaceTrainingDayOverride(_ override: TrainingDayOverride) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingDayOverride WHERE day = ?", arguments: [override.day])
            let ids: [UUID?] = override.isRest ? [nil] : override.routineIds.map(Optional.some)
            for (index, routineId) in ids.enumerated() {
                try db.execute(sql: """
                    INSERT INTO trainingDayOverride (day, idx, routineId, isRest) VALUES (?, ?, ?, ?)
                    """, arguments: [override.day, index, routineId?.uuidString, override.isRest])
            }
        }
    }

    public func deleteTrainingDayOverride(day: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingDayOverride WHERE day = ?", arguments: [day])
        }
    }

    public func trainingPlan(weekStartsOn: TrainingWeekStart = .monday) async throws -> TrainingPlan {
        let routines = try await trainingRoutines()
        return try syncRead { db in
            let scheduled = try Row.fetchAll(db, sql: "SELECT * FROM trainingSchedule ORDER BY weekday, idx")
            var schedule: [TrainingWeekday: [UUID]] = [:]
            for row in scheduled {
                guard let weekday = TrainingWeekday(rawValue: row["weekday"]),
                      let id = UUID(uuidString: row["routineId"]) else { continue }
                schedule[weekday, default: []].append(id)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM trainingDayOverride ORDER BY day, idx")
            var grouped: [String: (ids: [UUID], rest: Bool)] = [:]
            for row in rows {
                let day: String = row["day"]
                var value = grouped[day] ?? ([], false)
                value.rest = value.rest || (row["isRest"] as Bool)
                if let raw: String = row["routineId"], let id = UUID(uuidString: raw) { value.ids.append(id) }
                grouped[day] = value
            }
            let overrides = grouped.keys.sorted().map { day in
                TrainingDayOverride(day: day, routineIds: grouped[day]?.ids ?? [],
                                    isRest: grouped[day]?.rest ?? false)
            }
            return TrainingPlan(routines: routines, schedule: schedule,
                                overrides: overrides, weekStartsOn: weekStartsOn)
        }
    }

    public func saveWorkoutDraft(_ draft: WorkoutDraft) async throws {
        let payload = try JSONEncoder().encode(draft)
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingWorkoutDraft WHERE id <> ?", arguments: [draft.id.uuidString])
            try db.execute(sql: """
                INSERT INTO trainingWorkoutDraft (id, updatedAtTs, payload) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET updatedAtTs=excluded.updatedAtTs, payload=excluded.payload
                """, arguments: [draft.id.uuidString, draft.updatedAt, payload])
        }
    }

    public func workoutDraft() async throws -> WorkoutDraft? {
        try syncRead { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM trainingWorkoutDraft ORDER BY updatedAtTs DESC LIMIT 1") else {
                return nil
            }
            return try JSONDecoder().decode(WorkoutDraft.self, from: data)
        }
    }

    @discardableResult
    public func pruneWorkoutDrafts(olderThan cutoffTs: Int) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingWorkoutDraft WHERE updatedAtTs < ?", arguments: [cutoffTs])
            return db.changesCount
        }
    }

    public func completeNativeWorkout(_ workout: NativeWorkout) async throws {
        try syncWrite { db in
            try Self.write(workout, db: db)
            try db.execute(sql: "DELETE FROM trainingWorkoutDraft WHERE id = ?", arguments: [workout.id.uuidString])
        }
    }

    /// One transaction for a user-selected history import. Re-importing the same source file is safe
    /// because import adapters derive stable workout ids and every child row is replaced atomically.
    public func upsertNativeWorkouts(_ workouts: [NativeWorkout]) async throws {
        guard !workouts.isEmpty else { return }
        try syncWrite { db in
            for workout in workouts { try Self.write(workout, db: db) }
        }
    }

    public func nativeWorkouts(from: Int, to: Int, limit: Int = 2_000) async throws -> [NativeWorkout] {
        try syncRead { db in
            let heads = try Row.fetchAll(db, sql: """
                SELECT * FROM trainingWorkoutNative WHERE startedAtTs >= ? AND startedAtTs <= ?
                ORDER BY startedAtTs DESC LIMIT ?
                """, arguments: [from, to, max(1, limit)])
            guard !heads.isEmpty else { return [] }
            let ids = heads.map { $0["id"] as String }
            let marks = databaseQuestionMarks(count: ids.count)
            let exerciseRows = try Row.fetchAll(db, sql: """
                SELECT * FROM trainingWorkoutExercise WHERE workoutId IN (\(marks)) ORDER BY workoutId, idx
                """, arguments: StatementArguments(ids))
            let exerciseIds = exerciseRows.map { $0["id"] as String }
            let setMarks = databaseQuestionMarks(count: exerciseIds.count)
            let setRows = exerciseIds.isEmpty ? [] : try Row.fetchAll(db, sql: """
                SELECT * FROM trainingWorkoutSet WHERE workoutExerciseId IN (\(setMarks))
                ORDER BY workoutExerciseId, idx
                """, arguments: StatementArguments(exerciseIds))
            var sets: [String: [NativeWorkoutSet]] = [:]
            for row in setRows {
                let owner: String = row["workoutExerciseId"]
                guard let id = UUID(uuidString: row["id"]) else { continue }
                let effortScale: String? = row["effortScale"]
                let effortValue: Double? = row["effortValue"]
                let effort = effortScale.flatMap(TrainingEffortScale.init(rawValue:)).flatMap { scale in
                    effortValue.flatMap { TrainingEffortRating(scale: scale, value: $0) }
                }
                sets[owner, default: []].append(NativeWorkoutSet(
                    id: id, index: row["idx"], phase: TrainingSetPhase(rawValue: row["phase"]) ?? .work,
                    intensifier: TrainingSetIntensifier(rawValue: row["intensifier"]) ?? .none,
                    weightKg: row["weightKg"], reps: row["reps"], leftReps: row["leftReps"],
                    rightReps: row["rightReps"], durationS: row["durationS"], distanceM: row["distanceM"],
                    effort: effort, isCompleted: row["isCompleted"]))
            }
            var exercises: [String: [NativeWorkoutExercise]] = [:]
            for row in exerciseRows {
                let owner: String = row["workoutId"]
                let rawId: String = row["id"]
                guard let id = UUID(uuidString: rawId) else { continue }
                exercises[owner, default: []].append(NativeWorkoutExercise(
                    id: id, exerciseId: row["exerciseId"],
                    routineId: (row["routineId"] as String?).flatMap(UUID.init(uuidString:)),
                    sets: sets[rawId] ?? [], restSeconds: row["restSeconds"],
                    supersetId: (row["supersetId"] as String?).flatMap(UUID.init(uuidString:)),
                    excludeFromProgression: row["excludeFromProgression"], note: row["note"]))
            }
            return try heads.compactMap { row in
                let rawId: String = row["id"]
                guard let id = UUID(uuidString: rawId) else { return nil }
                let trackerRaw: String? = row["trackerJSON"]
                return NativeWorkout(id: id, title: row["title"], startedAt: row["startedAtTs"],
                    endedAt: row["endedAtTs"], plannedDay: row["plannedDay"],
                    routineIds: try Self.decode([UUID].self, row["routineIdsJSON"]),
                    exercises: exercises[rawId] ?? [],
                    tracker: try trackerRaw.map { try Self.decode(SessionTrackerAttribution.self, $0) },
                    sessionRPE: row["sessionRPE"], note: row["note"],
                    source: TrainingRecordSource(rawValue: row["source"]) ?? .imported)
            }
        }
    }

    public func deleteNativeWorkout(id: UUID) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingWorkoutNative WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private static func write(_ workout: NativeWorkout, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO trainingWorkoutNative
              (id, title, startedAtTs, endedAtTs, plannedDay, routineIdsJSON, trackerJSON, sessionRPE, note, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, startedAtTs=excluded.startedAtTs,
              endedAtTs=excluded.endedAtTs, plannedDay=excluded.plannedDay,
              routineIdsJSON=excluded.routineIdsJSON, trackerJSON=excluded.trackerJSON,
              sessionRPE=excluded.sessionRPE, note=excluded.note, source=excluded.source
            """, arguments: [workout.id.uuidString, workout.title, workout.startedAt, workout.endedAt,
                              workout.plannedDay, try json(workout.routineIds),
                              try workout.tracker.map(json), workout.sessionRPE, workout.note,
                              workout.source.rawValue])
        try db.execute(sql: "DELETE FROM trainingWorkoutExercise WHERE workoutId = ?",
                       arguments: [workout.id.uuidString])
        for (index, exercise) in workout.exercises.enumerated() {
            try db.execute(sql: """
                INSERT INTO trainingWorkoutExercise
                  (id, workoutId, idx, exerciseId, routineId, restSeconds, supersetId,
                   excludeFromProgression, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [exercise.id.uuidString, workout.id.uuidString, index,
                                  exercise.exerciseId, exercise.routineId?.uuidString,
                                  exercise.restSeconds, exercise.supersetId?.uuidString,
                                  exercise.excludeFromProgression, exercise.note])
            for (setIndex, set) in exercise.sets.enumerated() {
                try db.execute(sql: """
                    INSERT INTO trainingWorkoutSet
                      (id, workoutExerciseId, idx, phase, intensifier, weightKg, reps, leftReps,
                       rightReps, durationS, distanceM, effortScale, effortValue, isCompleted)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [set.id.uuidString, exercise.id.uuidString, setIndex,
                                      set.phase.rawValue, set.intensifier.rawValue, set.weightKg,
                                      set.reps, set.leftReps, set.rightReps, set.durationS, set.distanceM,
                                      set.effort?.scale.rawValue, set.effort?.value, set.isCompleted])
            }
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }
}
