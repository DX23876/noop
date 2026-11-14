import Foundation
import GRDB
import StrandTraining

/// Plans: the objects routines and scheduled days belong to, and the one place that decides which of
/// them is being followed.
///
/// `trainingPlan` resolves to the ACTIVE plans only (`NativeTrainingStore`), so every surface that
/// asks what to train today keeps asking one question and a resting plan cannot be started by
/// accident. Reading a resting plan is deliberate and goes through `trainingRoutines(programId:)`.
extension WhoopStore {

    public func trainingPrograms() async throws -> [TrainingProgram] {
        try syncRead { db in try Self.readPrograms(db) }
    }

    static func readPrograms(_ db: Database) throws -> [TrainingProgram] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM trainingProgram ORDER BY createdAtTs")
        let scheduleRows = try Row.fetchAll(db, sql: """
            SELECT programId, weekday, idx, routineId FROM trainingSchedule ORDER BY programId, weekday, idx
            """)
        var schedules: [String: [TrainingWeekday: [UUID]]] = [:]
        for row in scheduleRows {
            let owner: String = row["programId"]
            guard let weekday = TrainingWeekday(rawValue: row["weekday"]),
                  let id = UUID(uuidString: row["routineId"]) else { continue }
            schedules[owner, default: [:]][weekday, default: []].append(id)
        }
        return try rows.compactMap { row in
            let rawId: String = row["id"]
            guard let id = UUID(uuidString: rawId) else { return nil }
            let blockRaw: String? = row["blockJSON"]
            return TrainingProgram(
                id: id, title: row["title"],
                kind: TrainingProgramKind(rawValue: row["kind"]) ?? .strength,
                notes: row["notes"],
                targets: try Self.decode(TrainingProgramTargets.self, row["targetsJSON"]),
                block: try blockRaw.map { try Self.decode(TrainingProgramBlock.self, $0) },
                schedule: schedules[rawId] ?? [:],
                isActive: row["isActive"],
                origin: try Self.decode(TrainingProgramOrigin.self, row["originJSON"]),
                createdAt: row["createdAtTs"], updatedAt: row["updatedAtTs"])
        }
    }

    /// Writes the plan itself. Its schedule travels with it, so saving a plan and saving its week are
    /// one write and cannot half-land.
    ///
    /// A plan whose week names routines that are not stored yet must go through
    /// `upsertTrainingPlan(_:routines:)` instead: a schedule row points at a routine, so writing the
    /// week first is a foreign-key violation and the whole write fails.
    public func upsertTrainingProgram(_ program: TrainingProgram) async throws {
        try syncWrite { db in
            try Self.writeProgram(program, in: db)
            try Self.enforceActivation(program, in: db)
        }
    }

    /// A whole plan in one transaction: the plan row, its routines, then its week.
    ///
    /// That order is the point. A `trainingSchedule` row references the routine it names, so writing
    /// the week before the routines exist fails the foreign key and loses the entire plan, which is
    /// exactly what the builder, the ready-made plans and a plan copy did. One call does it right for
    /// every caller rather than three call sites each remembering to.
    public func upsertTrainingPlan(_ program: TrainingProgram,
                                   routines: [TrainingRoutine]) async throws {
        try syncWrite { db in
            var withoutWeek = program
            withoutWeek.schedule = [:]
            try Self.writeProgram(withoutWeek, in: db)
            for routine in routines {
                var placed = routine
                placed.programId = program.id
                try Self.writeTrainingRoutine(placed, in: db)
            }
            try Self.writeSchedule(program.schedule, programId: program.id, in: db)
            try Self.enforceActivation(program, in: db)
        }
    }

    /// Keeps the stored plans honest after a write: at most one active plan per kind, and no block run
    /// left open for a plan that no longer has a block.
    ///
    /// It lives here because the kind of an ACTIVE plan can be edited, and nothing else re-runs the
    /// rule: two plans of one kind would then both read as followed while only one of them reached
    /// Today.
    static func enforceActivation(_ program: TrainingProgram, in db: Database) throws {
        if program.isActive {
            let programs = try Self.readPrograms(db)
            let now = Int(Date().timeIntervalSince1970)
            let day = program.block?.startedOn ?? TrainingBlockState.dayKey(Date())
            for changed in TrainingProgramActivation.activate(program.id, in: programs,
                                                              day: day, now: now)
            where changed.id != program.id {
                try Self.writeProgram(changed, in: db)
                try Self.closeBlockRun(programId: changed.id, day: day, outcome: .abandoned, in: db)
            }
        }
        // A plan with no block has no run to be in. Leaving one open kept "this block so far" on the
        // page for a block that had been switched off.
        if program.block == nil {
            try Self.closeBlockRun(programId: program.id, day: TrainingBlockState.dayKey(Date()),
                                   outcome: .abandoned, in: db)
        }
    }

    static func writeProgram(_ program: TrainingProgram, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO trainingProgram
              (id, title, kind, notes, targetsJSON, blockJSON, isActive, originJSON,
               createdAtTs, updatedAtTs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, kind=excluded.kind,
              notes=excluded.notes, targetsJSON=excluded.targetsJSON, blockJSON=excluded.blockJSON,
              isActive=excluded.isActive, originJSON=excluded.originJSON,
              updatedAtTs=excluded.updatedAtTs
            """, arguments: [program.id.uuidString, program.title, program.kind.rawValue,
                              program.notes, try Self.json(program.targets),
                              try program.block.map(Self.json), program.isActive,
                              try Self.json(program.origin), program.createdAt, program.updatedAt])
        try Self.writeSchedule(program.schedule, programId: program.id, in: db)
    }

    /// Removes a plan with its routines and its week. Completed workouts are untouched: they live in
    /// their own tables and keep what was logged, exactly as deleting a single routine already did.
    public func deleteTrainingProgram(id: UUID) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingSchedule WHERE programId = ?",
                           arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM trainingRoutineNative WHERE programId = ?",
                           arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM trainingProgram WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Takes a plan up, standing down whatever plan of the same kind was being followed. The rule for
    /// what may run beside what lives in `TrainingProgramActivation`, tested there, and this only
    /// writes what it returns.
    ///
    /// A block starts counting from `day`, which is why the day is passed in rather than read here.
    @discardableResult
    public func activateTrainingProgram(id: UUID, day: String, now: Int) async throws -> Bool {
        try syncWrite { db in
            let programs = try Self.readPrograms(db)
            let changed = TrainingProgramActivation.activate(id, in: programs, day: day, now: now)
            for program in changed { try Self.writeProgram(program, in: db) }
            // A plan taken up with a block opens a run; the plan it replaced closes its own.
            for program in changed {
                if program.isActive, let block = program.block {
                    try Self.openBlockRun(program: program, block: block, day: day, in: db)
                } else if !program.isActive {
                    try Self.closeBlockRun(programId: program.id, day: day,
                                           outcome: .abandoned, in: db)
                }
            }
            return !changed.isEmpty
        }
    }

    @discardableResult
    public func deactivateTrainingProgram(id: UUID, day: String, now: Int) async throws -> Bool {
        try syncWrite { db in
            let programs = try Self.readPrograms(db)
            let changed = TrainingProgramActivation.deactivate(id, in: programs, now: now)
            for program in changed { try Self.writeProgram(program, in: db) }
            if !changed.isEmpty {
                try Self.closeBlockRun(programId: id, day: day, outcome: .abandoned, in: db)
            }
            return !changed.isEmpty
        }
    }

    // MARK: - Schedule

    static func writeSchedule(_ schedule: [TrainingWeekday: [UUID]], programId: UUID,
                              in db: Database) throws {
        try db.execute(sql: "DELETE FROM trainingSchedule WHERE programId = ?",
                       arguments: [programId.uuidString])
        for weekday in TrainingWeekday.allCases {
            for (index, routineId) in (schedule[weekday] ?? []).enumerated() {
                try db.execute(sql: """
                    INSERT INTO trainingSchedule (programId, weekday, idx, routineId) VALUES (?, ?, ?, ?)
                    """, arguments: [programId.uuidString, weekday.rawValue, index, routineId.uuidString])
            }
        }
    }

    // MARK: - Block runs

    /// Opens a run for a block that has just started, unless one is already open for that plan and day.
    static func openBlockRun(program: TrainingProgram, block: TrainingProgramBlock,
                             day: String, in db: Database) throws {
        let open = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM trainingBlockRun WHERE programId = ? AND endedOn IS NULL
            """, arguments: [program.id.uuidString]) ?? 0
        guard open == 0 else { return }
        try db.execute(sql: """
            INSERT INTO trainingBlockRun
              (id, programId, startedOn, endedOn, weeks, deloadInFinalWeek, deloadEveryWeeks,
               deloadFactor, progression, outcome)
            VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, program.id.uuidString, day, block.weeks,
                              block.deloadInFinalWeek, block.deloadEveryWeeks, block.deloadFactor,
                              block.progression.rawValue, TrainingBlockRun.Outcome.running.rawValue])
    }

    /// Closes whatever run is open for a plan. Nothing happens when none is.
    static func closeBlockRun(programId: UUID, day: String,
                              outcome: TrainingBlockRun.Outcome, in db: Database) throws {
        try db.execute(sql: """
            UPDATE trainingBlockRun SET endedOn = ?, outcome = ?
            WHERE programId = ? AND endedOn IS NULL
            """, arguments: [day, outcome.rawValue, programId.uuidString])
    }

    public func trainingBlockRuns(programId: UUID? = nil) async throws -> [TrainingBlockRun] {
        try syncRead { db in
            let rows: [Row]
            if let programId {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM trainingBlockRun WHERE programId = ? ORDER BY startedOn
                    """, arguments: [programId.uuidString])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM trainingBlockRun ORDER BY startedOn")
            }
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let program = UUID(uuidString: row["programId"]) else { return nil }
                return TrainingBlockRun(
                    id: id, programId: program, startedOn: row["startedOn"], endedOn: row["endedOn"],
                    weeks: row["weeks"], deloadInFinalWeek: row["deloadInFinalWeek"],
                    deloadEveryWeeks: row["deloadEveryWeeks"], deloadFactor: row["deloadFactor"],
                    progression: BlockProgressionPolicy(rawValue: row["progression"]) ?? .none,
                    outcome: TrainingBlockRun.Outcome(rawValue: row["outcome"]) ?? .running)
            }
        }
    }

    /// Marks the open run of a plan as finished, which is what the plan's own end reports rather than
    /// anything the app decides on its own.
    public func finishTrainingBlockRun(programId: UUID, day: String) async throws {
        try syncWrite { db in
            try Self.closeBlockRun(programId: programId, day: day, outcome: .finished, in: db)
        }
    }
}
