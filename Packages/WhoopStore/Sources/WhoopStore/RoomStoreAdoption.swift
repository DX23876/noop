import Foundation
import GRDB

/// Fork (DX23876), Android without Room: copies an Android Room store (a live install's `whoop.db`, or the
/// database inside an Android `.noopbak`) into this store, so Android needs no Room code to keep its history.
///
/// Room and GRDB share the table and column names of every table both platforms carry (the schema oracle,
/// `schema_oracle.json`), so the copy is SQL over an attached file, by column NAME (the two orders differ in
/// `battery`). Any Room version works: a column the old file lacks takes the destination's default (or a zero of
/// its affinity when the destination declares none), a table it lacks is skipped.
///
/// Derived values follow the core: rows Kotlin computed (the `-noop` namespace) are left out from the strap's
/// first raw heart-rate sample on, where the core's rebuild scores again, and kept before it, where nothing
/// could recompute them. A night the wearer edited is an input and is always copied. Existing rows win
/// (`INSERT OR IGNORE`): on a live install the core already holds the same raw frames and the mirrored inputs.
public enum RoomStoreAdoption {
    /// What one adoption copied, and the two tombstone lists Room keeps in tables where the shared code reads
    /// UserDefaults (`sleep.dismissedSessions`, `workouts.dismissedDetected`).
    public struct Report: Sendable, Equatable {
        public var copiedRows: [String: Int] = [:]
        /// Tables Room had and this copy left alone, with the reason.
        public var skipped: [String: String] = [:]
        public var roomVersion: Int?
        public var dismissedSleepTokens: [String] = []
        /// The tombstones whose night the wearer hid from the deleted-nights list.
        public var hiddenDismissedSleepTokens: [String] = []
        public var dismissedWorkoutTokens: [String] = []
        public init() {}
    }

    public enum AdoptionError: Error, Equatable {
        /// The file is not a Room store (no `room_master_table`, no `android_metadata`).
        case notRoom
    }

    /// The tables both platforms carry, in an order that copies parents before the rows that point at them.
    static let sharedTables = [
        "device", "pairedDevice", "dayOwnership",
        "hrSample", "rrInterval", "gravitySample", "stepSample", "respSample", "skinTempSample", "spo2Sample",
        "sleepStateSample", "battery", "event", "ppgHrSample", "ppgWaveformSample", "ecgWaveformSample",
        "v18AuxSample", "appleDaily", "appleStepHour",
        "dailyMetric", "metricSeries", "sleepSession", "workout", "liveSession", "journal", "labMarker",
        "scoreInputProvenance", "dismissedSleep", "dismissedWorkout", "coachMessage",
        "liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet",
    ]

    /// Tables keyed by an autoincrement id that other rows point at. Copying them into a store that already
    /// has its own rows could pair a Room row with a core row under one id, so they are copied only into an
    /// empty table (a restore, or an install that never logged a lift in the core).
    static let idLinkedTables: Set<String> = ["liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet"]

    /// The time each computed table is keyed by: an epoch second, or a `yyyy-MM-dd` day.
    static let computedTime: [String: (column: String, isDay: Bool)] = [
        "dailyMetric": ("day", true), "metricSeries": ("day", true), "scoreInputProvenance": ("day", true),
        "sleepSession": ("startTs", false), "workout": ("startTs", false), "liveSession": ("startTs", false),
    ]

    static let chunkRows: Int64 = 200_000

    /// The Room store's identity as `BackupArchive.backupOrigin` judges it.
    static func isRoom(_ tables: Set<String>) -> Bool {
        tables.contains("room_master_table") || (tables.contains("android_metadata") && tables.contains("sqlite_sequence"))
    }
}

extension RoomStoreAdoption {
    /// Builds a fresh store at `destPath` (this package's migrations) from the Room store at `roomPath`, for a
    /// restore of an Android `.noopbak`. Synchronous, so the restore can run it on its staged copy.
    public static func convert(roomPath: String, toStoreAt destPath: String) throws -> Report {
        let queue = try DatabaseQueue(path: destPath)
        try WhoopStore.makeMigrator().migrate(queue)
        let report = try adopt(roomPath: roomPath, into: queue)
        try queue.close()
        return report
    }

    /// Copies the Room store at `roomPath` into `writer` and sets the analysis recipe back to 0, so the next
    /// daily pass rebuilds every derived table from the adopted inputs. The Room file is only read. Chunked
    /// transactions, so a large history never grows one write-ahead log the size of the store.
    public static func adopt(roomPath: String, into writer: any DatabaseWriter) throws -> Report {
        let report = try writer.writeWithoutTransaction { db -> Report in
            var report = Report()
            try db.execute(sql: "ATTACH DATABASE ? AS room", arguments: [roomPath])
            defer { try? db.execute(sql: "DETACH DATABASE room") }
            let roomTables = Set(try String.fetchAll(db, sql: "SELECT name FROM room.sqlite_master WHERE type = 'table'"))
            guard isRoom(roomTables) else { throw AdoptionError.notRoom }
            if roomTables.contains("room_master_table") {
                report.roomVersion = try Int.fetchOne(db, sql: "PRAGMA room.user_version")
            }
            let mainTables = Set(try String.fetchAll(db, sql: "SELECT name FROM main.sqlite_master WHERE type = 'table'"))
            let rawStart = try rawStartByStrap(db, roomTables: roomTables)

            for table in sharedTables where roomTables.contains(table) {
                guard mainTables.contains(table) else { report.skipped[table] = "noCoreTable"; continue }
                if idLinkedTables.contains(table),
                   try Int.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM main.\"\(table)\")") == 1 {
                    report.skipped[table] = "coreHasRows"
                    continue
                }
                report.copiedRows[table] = try copyRoomTable(table, db: db, rawStart: rawStart)
            }
            report.dismissedSleepTokens = try tombstones(db, table: "dismissedSleep", roomTables: roomTables)
            report.hiddenDismissedSleepTokens = try tombstones(db, table: "dismissedSleep", roomTables: roomTables,
                                                               where: "managementVisible = 0")
            report.dismissedWorkoutTokens = try tombstones(db, table: "dismissedWorkout", roomTables: roomTables)
            for table in roomTables.subtracting(sharedTables)
            where !table.hasPrefix("sqlite_") && !["room_master_table", "android_metadata"].contains(table) {
                report.skipped[table] = "androidOnly"
            }
            // Derived tables now hold Kotlin's rows from before the raw history and nothing after it: the
            // recipe starts over, and its rebuild resumes from the first step.
            try db.inTransaction {
                try db.execute(sql: """
                    INSERT INTO cursors (name, value) VALUES ('noopai:analysisRecipeVersion', 0)
                    ON CONFLICT(name) DO UPDATE SET value = 0
                    """)
                try db.execute(sql: "DELETE FROM cursors WHERE name = 'noopai:analysisRebuildPosition'")
                return .commit
            }
            return report
        }
        if let pool = writer as? DatabasePool {
            try? pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        }
        return report
    }

    /// Each strap's first raw heart-rate second in the Room store, keyed by the strap id.
    static func rawStartByStrap(_ db: Database, roomTables: Set<String>) throws -> [String: Int64] {
        guard roomTables.contains("hrSample") else { return [:] }
        var out: [String: Int64] = [:]
        let ids = try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM room.hrSample")
        for id in ids {
            if let first = try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM room.hrSample WHERE deviceId = ?",
                                              arguments: [id]) {
                out[id] = first
            }
        }
        return out
    }

    private static func columns(_ db: Database, schema: String, table: String) throws
        -> [(name: String, type: String, notNull: Bool, hasDefault: Bool)] {
        try Row.fetchAll(db, sql: "PRAGMA \(schema).table_info(\"\(table)\")").map {
            (name: $0["name"], type: ($0["type"] as String?)?.uppercased() ?? "",
             notNull: ($0["notnull"] as Int?) == 1, hasDefault: !($0["dflt_value"] as DatabaseValue).isNull)
        }
    }

    /// Copies one table in rowid chunks, each its own transaction. Returns the rows inserted.
    private static func copyRoomTable(_ table: String, db: Database, rawStart: [String: Int64]) throws -> Int {
        let main = try columns(db, schema: "main", table: table)
        let roomNames = Set(try columns(db, schema: "room", table: table).map(\.name))
        var targets: [String] = [], sources: [String] = []
        for column in main {
            if roomNames.contains(column.name) {
                targets.append("\"\(column.name)\""); sources.append("r.\"\(column.name)\"")
            } else if column.notNull && !column.hasDefault {
                // A column a later version added without a default: the zero of its affinity.
                targets.append("\"\(column.name)\"")
                sources.append(column.type.contains("TEXT") || column.type.contains("CHAR") ? "''" : "0")
            }
        }
        guard !targets.isEmpty else { return 0 }
        var filter = "1"
        if let time = RoomStoreAdoption.computedTime[table], roomNames.contains("deviceId"), roomNames.contains(time.column) {
            let edited = roomNames.contains("userEdited") ? " OR r.userEdited = 1" : ""
            let cutoffs = rawStart.map { id, ts -> String in
                let start = time.isDay ? "date(\(ts), 'unixepoch')" : "\(ts)"
                return "WHEN '\(id.replacingOccurrences(of: "'", with: "''"))-noop' THEN r.\"\(time.column)\" < \(start)"
            }
            // A computed row whose strap has raw data is kept only before that data starts.
            let keepComputed = cutoffs.isEmpty ? "1" : "CASE r.deviceId \(cutoffs.joined(separator: " ")) ELSE 1 END"
            filter = "(r.deviceId NOT LIKE '%-noop'\(edited) OR \(keepComputed))"
        }
        let insert = "INSERT OR IGNORE INTO main.\"\(table)\" (\(targets.joined(separator: ", "))) "
            + "SELECT \(sources.joined(separator: ", ")) FROM room.\"\(table)\" r WHERE \(filter)"
        guard let maxRowid = try? Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM room.\"\(table)\"") else {
            // WITHOUT ROWID: one statement.
            try db.inTransaction { try db.execute(sql: insert); return .commit }
            return db.changesCount
        }
        var copied = 0, low: Int64 = 0
        while low <= maxRowid {
            let high = low + RoomStoreAdoption.chunkRows
            try db.inTransaction {
                try db.execute(sql: insert + " AND r.rowid >= ? AND r.rowid < ?", arguments: [low, high])
                copied += db.changesCount
                return .commit
            }
            low = high
        }
        return copied
    }

    /// Room's tombstone rows as the `"startTs:endTs"` tokens the shared code stores.
    private static func tombstones(_ db: Database, table: String, roomTables: Set<String>,
                                   where condition: String = "1") throws -> [String] {
        guard roomTables.contains(table) else { return [] }
        let names = Set(try columns(db, schema: "room", table: table).map(\.name))
        guard names.contains("startTs"), names.contains("endTs") else { return [] }
        if condition != "1", !names.contains("managementVisible") { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT startTs, endTs FROM room.\"\(table)\" "
                                        + "WHERE \(condition) AND endTs > startTs ORDER BY startTs")
        return rows.map { "\($0["startTs"] as Int64):\($0["endTs"] as Int64)" }
    }
}

extension WhoopStore {
    /// `RoomStoreAdoption.adopt` into this store: an Android install moving its Room history into the core.
    /// Runs outside the store actor, so a large history does not hold the collector's executor.
    public nonisolated func adoptRoomStore(atPath roomPath: String) async throws -> RoomStoreAdoption.Report {
        try RoomStoreAdoption.adopt(roomPath: roomPath, into: dbWriter)
    }
}
