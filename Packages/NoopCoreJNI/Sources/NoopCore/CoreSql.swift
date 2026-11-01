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

    /// The rows `sql` returns, as `{"columns": [...], "rows": [[...], ...]}`.
    static func query(_ args: [String: Any]) async -> String {
        guard let writer = ShadowSession.storeAndPath?.0.registryWriter else { return #"{"error":"noStore"}"# }
        guard let statement = statement(args) else { return #"{"error":"invalid"}"# }
        do {
            let result = try await writer.read { db -> [String: Any] in
                let cursor = try Row.fetchCursor(db, sql: statement.sql, arguments: statement.arguments)
                var columns: [String]?
                var rows: [[Any]] = []
                while let row = try cursor.next() {
                    if columns == nil { columns = Array(row.columnNames) }
                    rows.append(row.databaseValues.map(json))
                }
                return ["columns": columns ?? [], "rows": rows]
            }
            return encode(result)
        } catch {
            return encode(["error": "sql", "detail": String(describing: error)])
        }
    }

    /// Runs every statement in one write transaction; `{"changes": [...], "lastRowid": n}` or an error, in which
    /// case nothing was written.
    static func exec(_ args: [String: Any]) async -> String {
        guard let writer = ShadowSession.storeAndPath?.0.registryWriter else { return #"{"error":"noStore"}"# }
        let raw = args["statements"] as? [[String: Any]] ?? []
        let statements = raw.compactMap(statement)
        guard !statements.isEmpty, statements.count == raw.count else { return #"{"error":"invalid"}"# }
        do {
            let result = try await writer.write { db -> [String: Any] in
                var changes: [Int] = []
                for statement in statements {
                    try db.execute(sql: statement.sql, arguments: statement.arguments)
                    changes.append(db.changesCount)
                }
                return ["changes": changes, "lastRowid": db.lastInsertedRowID]
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
