import Foundation
import GRDB
import WhoopStore

/// Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`): the Android app's data access,
/// answered by the core's own store. Room and GRDB share the table and column names of every table both carry
/// (`schema_oracle.json`), so the queries Android's DAO always ran run unchanged here, through the store's own
/// connection: a second SQLite library opening the same file in one process would lose its locks to the first.
///
/// Values cross as JSON: integers, doubles, text, null, and blobs as `{"b64": …}`.
enum CoreSql {
    struct Statement { let sql: String; let arguments: StatementArguments }

    /// Most rows one answer may carry, and the size it may reach while being built.
    ///
    /// A read has no ceiling of its own: the host sends a statement, every row is gathered here, encoded
    /// into one string, copied onto the Java heap and parsed there a second time, so the same rows exist
    /// four times over at the peak. Writes have been chunked since they were written (`CoreDb.BATCH`,
    /// "so one JSON hand-over stays a few megabytes"); reads never were, and the host's own reads ask for
    /// up to 200,000 sample rows at a time.
    ///
    /// These are deliberately far above any honest screen read — a day of heart rate is a few thousand
    /// rows — so this is not a budget callers have to plan against. It is the line past which an answer
    /// has stopped being a screen's data, where a refused read with a message beats an out-of-memory
    /// kill the report cannot attribute (2026-11-19).
    static let maxRows = 250_000
    static let maxValueBytes = 48 * 1_024 * 1_024

    /// The rows `sql` returns, as `{"columns": [...], "rows": [[...], ...]}`, or `{"error": "tooLarge"}`
    /// once the answer passes `maxRows` or `maxValueBytes`. The error names the statement so the host can
    /// say which read it was.
    static func query(_ args: [String: Any]) async -> String {
        guard let writer = ShadowSession.storeAndPath?.0.registryWriter else { return #"{"error":"noStore"}"# }
        guard let statement = statement(args) else { return #"{"error":"invalid"}"# }
        do {
            let result = try await writer.read { db -> [String: Any] in
                let cursor = try Row.fetchCursor(db, sql: statement.sql, arguments: statement.arguments)
                var columns: [String]?
                var rows: [[Any]] = []
                var bytes = 0
                while let row = try cursor.next() {
                    if columns == nil { columns = Array(row.columnNames) }
                    let values = row.databaseValues
                    bytes += values.reduce(0) { $0 + size($1) }
                    if rows.count >= maxRows || bytes > maxValueBytes {
                        return ["error": "tooLarge", "rows": rows.count, "bytes": bytes,
                                "sql": String(statement.sql.prefix(120))]
                    }
                    rows.append(values.map(json))
                }
                return ["columns": columns ?? [], "rows": rows]
            }
            return encode(result)
        } catch {
            return encode(["error": "sql", "detail": String(describing: error)])
        }
    }

    /// Roughly what one value will weigh in the answer. Not exact and does not need to be: it decides
    /// whether an answer has run away, and an escape or a quotation mark either way changes nothing.
    static func size(_ value: DatabaseValue) -> Int {
        switch value.storage {
        case .null: return 4
        case .int64, .double: return 8
        case .string(let s): return s.utf8.count + 2
        case .blob(let data): return (data.count + 2) / 3 * 4 + 9
        }
    }

    /// Runs every statement in one write transaction; `{"changes": [...], "rowids": [...]}` per statement, or an
    /// error, in which case nothing was written.
    static func exec(_ args: [String: Any]) async -> String {
        guard let writer = ShadowSession.storeAndPath?.0.registryWriter else { return #"{"error":"noStore"}"# }
        let raw = args["statements"] as? [[String: Any]] ?? []
        let statements = raw.compactMap(statement)
        guard !statements.isEmpty, statements.count == raw.count else { return #"{"error":"invalid"}"# }
        do {
            let result = try await writer.write { db -> [String: Any] in
                var changes: [Int] = [], rowids: [Int64] = []
                for statement in statements {
                    try db.execute(sql: statement.sql, arguments: statement.arguments)
                    changes.append(db.changesCount)
                    // Room's insert answer: the new row's id, or -1 when the conflict clause kept the old row.
                    rowids.append(db.changesCount > 0 ? db.lastInsertedRowID : -1)
                }
                // The day analysis reuses days whose inputs did not change; a host write must say they did.
                if changes.contains(where: { $0 > 0 }) { try WhoopStore.markHostWrite(db) }
                return ["changes": changes, "rowids": rowids]
            }
            return encode(result)
        } catch {
            return encode(["error": "sql", "detail": String(describing: error)])
        }
    }

    static func statement(_ args: [String: Any]) -> Statement? {
        guard let sql = args["sql"] as? String, !sql.isEmpty else { return nil }
        let values = (args["args"] as? [Any] ?? []).map(databaseValue)
        return Statement(sql: sql, arguments: StatementArguments(values))
    }

    static func databaseValue(_ value: Any) -> DatabaseValue {
        switch value {
        case is NSNull: return .null
        case let b as Bool: return (b ? 1 : 0).databaseValue
        case let n as NSNumber:
            // A whole number crosses as an integer: a REAL column stores it as a real all the same (its affinity
            // converts), and an INTEGER column must not receive 3.0.
            let d = n.doubleValue
            if d.rounded() == d, abs(d) < 9_007_199_254_740_992 { return n.int64Value.databaseValue }
            return d.databaseValue
        case let s as String: return s.databaseValue
        case let d as [String: Any]:
            if let b64 = d["b64"] as? String, let data = Data(base64Encoded: b64) { return data.databaseValue }
            return .null
        default: return .null
        }
    }

    static func json(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null: return NSNull()
        case .int64(let i): return i
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .blob(let data): return ["b64": data.base64EncodedString()]
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return #"{"error":"encode"}"# }
        return text
    }
}
