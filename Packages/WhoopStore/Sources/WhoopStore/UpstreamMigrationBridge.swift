import GRDB

/// Lets a database created by upstream NOOP (ryanbr/noop) open under this fork.
///
/// GRDB tracks applied migrations by IDENTIFIER. From v38 on, the fork and upstream numbered their
/// migrations independently, so several upstream migrations exist here with the SAME body under a
/// DIFFERENT identifier (the fork's own v38–v40 and v43–v50 came first and pushed upstream's later).
/// Opened unbridged, an upstream 11.5–11.7 store looks to the migrator as if those steps never ran, and
/// the first re-run `ALTER TABLE … ADD COLUMN` fails with "duplicate column name" — the store never
/// opens, so a wearer switching from upstream would see no history at all.
///
/// Before migrating, every upstream identifier that is recorded as applied also records its fork
/// equivalent, so the migrator skips a step whose schema change is already on disk. Only pairs whose
/// bodies were compared and found identical are listed (v51's body is a column-guarded superset of
/// upstream's v40). Upstream's own rows stay in `grdb_migrations`; GRDB ignores identifiers it does
/// not know. `v43-coach-messages` has no fork equivalent: the fork's Coach persists elsewhere, and the
/// leftover `coachMessage` table is inert. Nothing is ever deleted.
///
/// Extend this table when a later upstream sync appends a migration under a new fork number.
enum UpstreamMigrationBridge {
    /// Upstream identifier → the fork migration with the same effect.
    static let equivalents: [(upstream: String, fork: String)] = [
        ("v38-apple-step-hour", "v41-apple-step-hour"),
        ("v39-ppg-burst-index", "v42-ppg-burst-index"),
        ("v40-daily-skin-temp-absolute", "v51-daily-skin-temp-absolute"),
        ("v41-drop-raw-imu-sample", "v52-drop-raw-imu-sample"),
        ("v42-daily-sleep-hr-only", "v53-daily-sleep-hr-only"),
        ("v44-ppg-waveform-base-code", "v57-ppg-waveform-base-code"),
        ("v45-rr-source-index", "v68-rr-source-index"),
        ("v46-lift-log", "v69-lift-log"),
    ]

    /// Records the fork identifiers for already-applied upstream migrations. A no-op on a fresh file,
    /// on a fork-created store, and on every launch after the first bridged one.
    static func adopt(_ writer: some DatabaseWriter) throws {
        try writer.write { db in
            guard try db.tableExists("grdb_migrations") else { return }
            for pair in equivalents {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO grdb_migrations(identifier)
                    SELECT ? WHERE EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = ?)
                    """, arguments: [pair.fork, pair.upstream])
            }
        }
    }
}

extension WhoopStore {
    /// Whether this store was created by upstream NOOP: it records a migration identifier only upstream
    /// uses. Such a store carries no fork analysis-recipe cursor, and its derived rows were scored under
    /// upstream rules, so the app must not anchor them as current.
    public func openedFromUpstreamMigrations() async throws -> Bool {
        let ids = UpstreamMigrationBridge.equivalents.map(\.upstream) + ["v43-coach-messages"]
        return try syncRead { db in
            guard try db.tableExists("grdb_migrations") else { return false }
            let marks = databaseQuestionMarks(count: ids.count)
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier IN (\(marks)))
                """, arguments: StatementArguments(ids)) ?? false
        }
    }

    /// The earliest day on or after `since` whose computed row staged sleep but holds no HRV, or nil.
    ///
    /// Upstream 11.6/11.7 withheld unlabelled WHOOP 5 R-R and persisted exactly this shape: a night with
    /// sleep and no HRV (and therefore no Charge). It bounds how far back the repair pass has to reach.
    public func earliestSleptDayMissingHRV(deviceId: String, since: String) async throws -> String? {
        try syncRead { db in
            try String.fetchOne(db, sql: """
                SELECT MIN(day) FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND avgHrv IS NULL AND totalSleepMin > 0
                """, arguments: [deviceId, since])
        }
    }
}
