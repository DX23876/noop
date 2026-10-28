import Foundation
import GRDB

/// The Android input lanes the core takes over after the journal and water (parity plan 1.3): imported and
/// entered workouts, platform health days, lab markers, live sessions, imported series, imported days and
/// nights, manual naps and sleep edits, and day ownership. Android's Room tables share these schemas, so a
/// row crosses as its column values. Rows the Kotlin analysis computed (`<id>-noop`) never cross, except a
/// sleep session the wearer edited or added, which is input; the core recomputes everything else itself.
extension WhoopStore {
    public static let androidInputLanesOwnership = "android-input-lanes-v1"
    public static let androidInputLaneTables = ["workout", "appleDaily", "labMarker", "liveSession", "metricSeries",
                                                "dailyMetric", "sleepSession", "dayOwnership"]

    public enum InputLaneError: Error, Equatable { case unknownTable, unknownColumn(String), missingKey }

    /// One SQLite value as a host sends it; column affinity stores an integer in a REAL column as a real.
    public enum LaneValue: Equatable, Sendable {
        case null, integer(Int64), real(Double), text(String)
        var databaseValue: DatabaseValue {
            switch self {
            case .null: return .null
            case .integer(let v): return v.databaseValue
            case .real(let v): return v.databaseValue
            case .text(let v): return v.databaseValue
            }
        }
    }
    public typealias LaneRow = [String: LaneValue]

    public func ownsAndroidInputLanes() async throws -> Bool {
        try syncRead { db in try Self.laneOwned(db) }
    }

    /// Whether a legacy row belongs to a lane. Kotlin-computed rows stay behind; water is the journal lane's.
    public static func admitsLaneRow(table: String, row: LaneRow) -> Bool {
        let device: String
        if case .text(let id)? = row["deviceId"] { device = id } else { device = "" }
        if table == "metricSeries" && device == "hydration" { return false }
        guard device.hasSuffix(DeviceRegistryStore.computedSuffix) else { return true }
        guard table == "sleepSession" else { return false }
        if case .integer(let edited)? = row["userEdited"] { return edited != 0 }
        if case .real(let edited)? = row["userEdited"] { return edited != 0 }
        return false
    }

    /// Clears any partial staging so an interrupted adoption starts over from a complete snapshot.
    public func resetAndroidInputLaneStage() async throws {
        try syncWrite { db in
            for table in Self.androidInputLaneTables { try db.execute(sql: "DROP TABLE IF EXISTS \(Self.stage(table))") }
        }
    }

    /// Adds one chunk of a legacy table to its staging copy. Nothing is visible until the commit.
    public func stageAndroidInputLane(table: String, rows: [LaneRow]) async throws {
        try syncWrite { db in
            let columns = try Self.laneColumns(db, table)
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS \(Self.stage(table)) AS SELECT * FROM \(table) WHERE 0")
            for row in rows where Self.admitsLaneRow(table: table, row: row) {
                try Self.insert(db, into: Self.stage(table), row: row, columns: columns, conflict: "")
            }
        }
    }

    /// Moves every staged row in and seals the lanes, in one transaction. A first adoption keeps existing core
    /// rows (a restored backup or a newer core write wins); `replace` repairs a mirror that fell behind.
    @discardableResult
    public func commitAndroidInputLanes(replace: Bool) async throws -> Int {
        try syncWrite { db in
            var moved = 0
            var devices = Set<String>()
            for table in Self.androidInputLaneTables {
                let staged = Self.stage(table)
                guard try db.tableExists(staged) else { continue }
                let names = try Self.laneColumns(db, table).joined(separator: ", ")
                if table != "dayOwnership" {
                    devices.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM \(staged)"))
                }
                try db.execute(sql: "INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO \(table) (\(names)) SELECT \(names) FROM \(staged)")
                moved += db.changesCount
                try db.execute(sql: "DROP TABLE \(staged)")
            }
            try db.execute(sql: "INSERT INTO hostInputOwnership (key) VALUES (?) ON CONFLICT(key) DO NOTHING",
                           arguments: [Self.androidInputLanesOwnership])
            for device in devices { try Self.markAnalysisDeviceChanged(db, deviceId: device) }
            return moved
        }
    }

    /// Mirrors rows Android just wrote, as they ended up in its store.
    public func putAndroidInputLaneRows(table: String, rows: [LaneRow]) async throws {
        try syncWrite { db in
            let columns = try Self.laneColumns(db, table)
            var devices = Set<String>()
            for row in rows where Self.admitsLaneRow(table: table, row: row) {
                try Self.insert(db, into: table, row: row, columns: columns, conflict: "OR REPLACE")
                if case .text(let device)? = row["deviceId"] { devices.insert(device) }
            }
            for device in devices { try Self.markAnalysisDeviceChanged(db, deviceId: device) }
        }
    }

    /// Mirrors a delete Android just made: equality on `equals`, plus an inclusive range when given.
    @discardableResult
    public func deleteAndroidInputLaneRows(table: String, equals: LaneRow,
                                           range: (column: String, from: LaneValue, to: LaneValue)? = nil) async throws -> Int {
        try syncWrite { db in
            let columns = Set(try Self.laneColumns(db, table))
            guard !equals.isEmpty else { throw InputLaneError.missingKey }
            var clauses: [String] = []
            var arguments: [DatabaseValueConvertible?] = []
            for (column, value) in equals.sorted(by: { $0.key < $1.key }) {
                guard columns.contains(column) else { throw InputLaneError.unknownColumn(column) }
                clauses.append("\(column) = ?"); arguments.append(value.databaseValue)
            }
            if let range {
                guard columns.contains(range.column) else { throw InputLaneError.unknownColumn(range.column) }
                clauses.append("\(range.column) >= ? AND \(range.column) <= ?")
                arguments.append(range.from.databaseValue); arguments.append(range.to.databaseValue)
            }
            try db.execute(sql: "DELETE FROM \(table) WHERE \(clauses.joined(separator: " AND "))",
                           arguments: StatementArguments(arguments) ?? [])
            let removed = db.changesCount
            if removed > 0, case .text(let device)? = equals["deviceId"] {
                try Self.markAnalysisDeviceChanged(db, deviceId: device)
            }
            return removed
        }
    }

    static func laneOwned(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM hostInputOwnership WHERE key = ?)",
                          arguments: [androidInputLanesOwnership]) ?? false
    }

    static func sealAndroidInputLanes(in db: Database) throws {
        for table in androidInputLaneTables { try db.execute(sql: "DROP TABLE IF EXISTS \(stage(table))") }
        try db.execute(sql: "INSERT INTO hostInputOwnership (key) VALUES (?) ON CONFLICT(key) DO NOTHING",
                       arguments: [androidInputLanesOwnership])
    }

    private static func stage(_ table: String) -> String { "laneStage_\(table)" }

    private static func laneColumns(_ db: Database, _ table: String) throws -> [String] {
        guard androidInputLaneTables.contains(table) else { throw InputLaneError.unknownTable }
        return try db.columns(in: table).map(\.name)
    }

    private static func insert(_ db: Database, into table: String, row: LaneRow, columns: [String],
                               conflict: String) throws {
        let known = Set(columns)
        if let unknown = row.keys.first(where: { !known.contains($0) }) { throw InputLaneError.unknownColumn(unknown) }
        let present = columns.filter { row[$0] != nil }
        guard !present.isEmpty else { throw InputLaneError.missingKey }
        let marks = Array(repeating: "?", count: present.count).joined(separator: ", ")
        try db.execute(sql: "INSERT \(conflict) INTO \(table) (\(present.joined(separator: ", "))) VALUES (\(marks))",
                       arguments: StatementArguments(present.map { row[$0]!.databaseValue }) ?? [])
    }
}
