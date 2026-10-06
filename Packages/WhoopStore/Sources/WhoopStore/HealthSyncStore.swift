import Foundation
import GRDB

extension WhoopStore {
    static func createHealthSyncTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE healthExportChange (
                kind TEXT PRIMARY KEY NOT NULL, fromTs INTEGER NOT NULL,
                toTs INTEGER NOT NULL, revision INTEGER NOT NULL
            );
            CREATE TABLE healthExportVersion (
                id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL,
                revision INTEGER NOT NULL, committed INTEGER NOT NULL DEFAULT 0
            );
            """)
        // Triggers keep every mutation path (including Undo and raw SQL maintenance) transactional.
        // A retained row's disappearance is owed even if the app dies before its UI refresh.
        for (table, kind, start, end, eligible) in [
            ("workout", "workouts", "startTs", "endTs", "source != 'apple-health' AND (deviceId = 'my-whoop' OR deviceId = 'my-whoop-noop' OR deviceId LIKE 'whoop-%')"),
            ("sleepSession", "sleep", "startTs", "endTs", "deviceId = 'my-whoop' OR deviceId = 'my-whoop-noop' OR deviceId LIKE 'whoop-%'"),
            ("trainingWorkoutNative", "workouts", "startedAtTs", "endedAtTs", "1"),
            ("dailyMetric", "vitals", "day", "day", "deviceId = 'my-whoop' OR deviceId = 'my-whoop-noop' OR deviceId LIKE 'whoop-%'"),
            ("bodyWeightEntry", "weight", "takenAt", "takenAt", "source = 'manual'"),
            ("labMarker", "waist", "takenAt", "takenAt", "source IN ('manual', 'profile') AND markerKey = 'waist'")
        ] {
            for (event, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                var predicate = eligible.replacingOccurrences(of: "source", with: "\(row).source")
                    .replacingOccurrences(of: "deviceId", with: "\(row).deviceId")
                    .replacingOccurrences(of: "markerKey", with: "\(row).markerKey")
                if event == "UPDATE" {
                    let oldPredicate = eligible.replacingOccurrences(of: "source", with: "OLD.source")
                        .replacingOccurrences(of: "deviceId", with: "OLD.deviceId")
                        .replacingOccurrences(of: "markerKey", with: "OLD.markerKey")
                    predicate = "(\(predicate)) OR (\(oldPredicate))"
                }
                func boundary(_ owner: String, field: String, ending: Bool) -> String {
                    guard table == "dailyMetric" else { return "\(owner).\(field)" }
                    let midnight = "CAST(strftime('%s', \(owner).day) AS INTEGER)"
                    return ending ? "(\(midnight) + 86399)" : midnight
                }
                let from = event == "UPDATE" ? "MIN(\(boundary("OLD", field: start, ending: false)), \(boundary("NEW", field: start, ending: false)))" : boundary(row, field: start, ending: false)
                let to = event == "UPDATE" ? "MAX(\(boundary("OLD", field: end, ending: true)), \(boundary("NEW", field: end, ending: true)))" : boundary(row, field: end, ending: true)
                try db.execute(sql: """
                    CREATE TRIGGER health_\(table)_\(event.lowercased()) AFTER \(event) ON \(table)
                    WHEN \(predicate)
                    BEGIN
                        INSERT INTO healthExportChange(kind, fromTs, toTs, revision)
                        VALUES ('\(kind)', \(from), \(to), 1)
                        ON CONFLICT(kind) DO UPDATE SET
                            fromTs = MIN(fromTs, excluded.fromTs), toTs = MAX(toTs, excluded.toTs),
                            revision = revision + 1;
                    END;
                    """)
            }
        }
    }

    /// Coalesce an affected interval without advancing or dropping an existing pending revision.
    public func enqueueHealthExport(kind: String, fromTs: Int, toTs: Int) async throws {
        try syncWrite { db in
            try Self.enqueueHealthExport(db, kind: kind, fromTs: fromTs, toTs: toTs)
        }
    }

    static func enqueueHealthExport(_ db: Database, kind: String, fromTs: Int, toTs: Int) throws {
        guard fromTs >= 0, toTs >= fromTs else { return }
        try db.execute(sql: """
            INSERT INTO healthExportChange(kind, fromTs, toTs, revision) VALUES (?, ?, ?, 1)
            ON CONFLICT(kind) DO UPDATE SET fromTs = MIN(fromTs, excluded.fromTs),
                toTs = MAX(toTs, excluded.toTs), revision = revision + 1
            """, arguments: [kind, fromTs, toTs])
    }

    public func pendingHealthExports() async throws -> [HealthSyncState.Change] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM healthExportChange ORDER BY kind").map {
                .init(kind: $0["kind"], fromTs: $0["fromTs"], toTs: $0["toTs"], revision: $0["revision"])
            }
        }
    }

    /// A mutation arriving while HealthKit is suspended must survive acknowledgement of an older pass.
    public func acknowledgeHealthExport(_ change: HealthSyncState.Change) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM healthExportChange WHERE kind = ? AND revision = ?",
                           arguments: [change.kind, change.revision])
        }
    }

    /// Reserve versions before external writes. A retry of the same interrupted save uses the same
    /// version; a changed payload gets a higher one. Committed identical payloads need no new Health UUID.
    public func planHealthExports(_ values: [(id: String, fingerprint: String)], versionFloor: Int = Int(Date().timeIntervalSince1970 * 1_000)) async throws -> [HealthSyncState.ExportVersion] {
        try syncWrite { db in
            try values.map { value in
                let prior = try Row.fetchOne(db, sql: "SELECT * FROM healthExportVersion WHERE id = ?", arguments: [value.id])
                let same = (prior?["fingerprint"] as String?) == value.fingerprint
                // A restored older backup must still exceed Health's previously saved version.
                let revision = same ? (prior?["revision"] as Int? ?? 1) : max(max(1, versionFloor), (prior?["revision"] as Int? ?? 0) + 1)
                let needsSave = !same || (prior?["committed"] as Int? ?? 0) == 0
                if !same {
                    try db.execute(sql: """
                        INSERT INTO healthExportVersion(id, fingerprint, revision, committed) VALUES (?, ?, ?, 0)
                        ON CONFLICT(id) DO UPDATE SET fingerprint = excluded.fingerprint,
                            revision = excluded.revision, committed = 0
                        """, arguments: [value.id, value.fingerprint, revision])
                }
                return .init(id: value.id, revision: revision, needsSave: needsSave)
            }
        }
    }

    public func commitHealthExports(_ versions: [HealthSyncState.ExportVersion]) async throws {
        try syncWrite { db in
            for value in versions {
                try db.execute(sql: "UPDATE healthExportVersion SET committed = 1 WHERE id = ? AND revision = ?",
                               arguments: [value.id, value.revision])
            }
        }
    }

    /// Preserve the monotonically increasing version across delete/Undo cycles.
    public func invalidateHealthExports(ids: [String]) async throws {
        try syncWrite { db in
            for id in ids {
                try db.execute(sql: "UPDATE healthExportVersion SET fingerprint = '', committed = 0 WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Persist the dates before deleting UUID metadata, so a failed Health re-query can resume later.
    public func queueDeletedHealthWorkoutRepair(externalIds: [String]) async throws {
        try syncWrite { db in
            let ids = Set(externalIds.map { $0.lowercased() })
            let rows = try Row.fetchAll(db, sql: "SELECT externalId, startTs FROM workoutSourceMetadata WHERE source = 'apple-health'")
            let starts: [Int] = rows.compactMap { row in
                guard let id: String = row["externalId"], ids.contains(id) else { return nil }
                return row["startTs"]
            }
            if let first = starts.min(), let last = starts.max() {
                try Self.enqueueHealthExport(db, kind: "importWorkouts", fromTs: first, toTs: last)
            }
        }
    }

    public func advanceHealthExport(_ change: HealthSyncState.Change, pastTs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE healthExportChange SET fromTs = ? WHERE kind = ? AND revision = ? AND fromTs < ?",
                arguments: [pastTs, change.kind, change.revision, pastTs])
        }
    }

    /// Delete only UUID-identified imported workouts, never local rows or user session decisions.
    /// Another Health UUID at the same legacy natural key retains its row until that UUID also disappears.
    public func deleteImportedHealthWorkouts(externalIds: [String], deviceId: String) async throws -> Int? {
        try syncWrite { db in
            var oldest: Int?
            for id in externalIds {
                let matches = try Row.fetchAll(db, sql: """
                    SELECT * FROM workoutSourceMetadata WHERE source = 'apple-health' AND externalId = ?
                    """, arguments: [id.lowercased()])
                for row in matches {
                    let key: String = row["componentKey"], start: Int = row["startTs"], sport: String = row["sport"]
                    oldest = min(oldest ?? start, start)
                    let other = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM workoutSourceMetadata
                        WHERE source = 'apple-health' AND startTs = ? AND sport = ? AND componentKey != ?
                        """, arguments: [start, sport, key]) ?? 0
                    if other == 0 {
                        try db.execute(sql: "DELETE FROM workout WHERE deviceId = ? AND source = 'apple-health' AND startTs = ? AND sport = ?", arguments: [deviceId, start, sport])
                        try db.execute(sql: "DELETE FROM workoutHeartRateFill WHERE deviceId = ? AND startTs = ? AND sport = ?", arguments: [deviceId, start, sport])
                    }
                    // Stored loads for this exact start must be recomputed after a component disappears.
                    try db.execute(sql: "DELETE FROM trainingSessionLoad WHERE startTs = ?", arguments: [start])
                    try db.execute(sql: "DELETE FROM trainingSessionLink WHERE componentKey = ? AND origin = 'watch-workout-metadata'", arguments: [key])
                    try db.execute(sql: "DELETE FROM workoutSourceMetadata WHERE componentKey = ?", arguments: [key])
                }
            }
            return oldest
        }
    }
}

extension WhoopStore {
    public func staleHealthWorkoutIDs(from: Int, to: Int, keeping: Set<String>) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT externalId FROM workoutSourceMetadata WHERE source = 'apple-health' AND externalId IS NOT NULL AND startTs >= ? AND startTs < ?", arguments: [from, to]).filter { !keeping.contains($0) }
        }
    }
}
