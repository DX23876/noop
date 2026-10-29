import Foundation
import WhoopStore

/// Raw journal and water storage for Android. The host only transports exact source rows; ownership,
/// atomic adoption and backup replay protection live in WhoopStore.
enum CoreUserInputs {
    struct Snapshot: Decodable {
        let journal: [LegacyJournalInput]
        let hydration: [MetricPoint]
    }
    struct JournalRows: Decodable { let rows: [JournalEntry] }
    struct WaterRows: Decodable { let rows: [MetricPoint] }

    static func run(_ op: String, json: String, store: WhoopStore) async -> String {
        do {
            let data = Data(json.utf8)
            let args = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            func string(_ key: String) throws -> String {
                guard let value = args[key] as? String else { throw InputError.missingArgument }
                return value
            }
            switch op {
            case "input.ownership": return CoreRead.json(["owned": try await store.ownsAndroidJournalHydration()])
            case "input.adopt":
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                _ = try await store.adoptAndroidJournalHydration(journal: snapshot.journal, hydration: snapshot.hydration)
            case "input.journalRead":
                return CoreRead.json(try await store.journalEntries(deviceId: string("source"),
                                                                   from: string("from"), to: string("to")))
            case "input.journalWrite":
                let rows = try JSONDecoder().decode(JournalRows.self, from: data).rows
                _ = try await store.upsertJournal(rows, deviceId: string("source"))
            case "input.journalDelete":
                _ = try await store.deleteJournal(deviceId: string("source"), day: string("day"), question: string("question"))
            case "input.journalReplace":
                let rows = try JSONDecoder().decode(JournalRows.self, from: data).rows
                let from = try string("from"), to = try string("to")
                guard from <= to, rows.allSatisfy({ $0.day >= from && $0.day <= to }) else { throw InputError.outsideWindow }
                _ = try await store.replaceJournalRange(rows, deviceId: string("source"), from: from, to: to)
            case "input.waterKeys": return CoreRead.json(try await store.metricKeys(deviceId: "hydration"))
            case "input.waterCount":
                return CoreRead.json(["count": try await store.metricSeriesKeyCount(deviceId: "hydration", key: waterKey(args))])
            case "input.waterRead":
                return CoreRead.json(try await store.metricSeries(deviceId: "hydration", key: waterKey(args),
                                                                 from: string("from"), to: string("to")))
            case "input.waterWrite":
                let rows = try JSONDecoder().decode(WaterRows.self, from: data).rows
                guard rows.allSatisfy({ validWaterKey($0.key) && $0.value.isFinite }) else { throw InputError.missingArgument }
                _ = try await store.upsertMetricSeries(rows, deviceId: "hydration")
            case "input.waterDelete":
                _ = try await store.deleteMetricSeriesPoint(deviceId: "hydration", day: string("day"), key: waterKey(args))
            case "lanes.owned": return CoreRead.json(["owned": try await store.ownsAndroidInputLanes()])
            case "lanes.reset": try await store.resetAndroidInputLaneStage()
            case "lanes.stage": try await store.stageAndroidInputLane(table: string("table"), rows: rows(args))
            case "lanes.commit":
                return CoreRead.json(["moved": try await store.commitAndroidInputLanes(replace: args["replace"] as? Bool ?? false)])
            case "lanes.put": try await store.putAndroidInputLaneRows(table: string("table"), rows: rows(args))
            case "lanes.delete":
                let equals = ((args["equals"] as? [String: Any]) ?? [:]).mapValues(databaseValue)
                var range: (column: String, from: WhoopStore.LaneValue, to: WhoopStore.LaneValue)?
                if let r = args["range"] as? [String: Any], let column = r["column"] as? String {
                    range = (column, databaseValue(r["from"] ?? NSNull()), databaseValue(r["to"] ?? NSNull()))
                }
                return CoreRead.json(["removed": try await store.deleteAndroidInputLaneRows(table: string("table"),
                                                                                           equals: equals, range: range)])
            case "input.waterDeleteSeries":
                _ = try await store.deleteMetricSeries(deviceId: "hydration", key: waterKey(args))
            default: return #"{"error":"unknownInputOperation"}"#
            }
            return #"{"ok":true}"#
        } catch { return #"{"error":"inputUnavailable"}"# }
    }

    private enum InputError: Error { case missingArgument, outsideWindow }

    /// A Room row as it crossed: column names to SQLite values. Column affinity stores 3 as 3.0 in a REAL column.
    private static func rows(_ args: [String: Any]) throws -> [WhoopStore.LaneRow] {
        guard let list = args["rows"] as? [[String: Any]] else { throw InputError.missingArgument }
        return list.map { $0.mapValues(databaseValue) }
    }

    private static func databaseValue(_ value: Any) -> WhoopStore.LaneValue {
        switch value {
        case is NSNull: return .null
        case let text as String: return .text(text)
        case let number as NSNumber:
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 9.0e15 { return .integer(Int64(double)) }
            return .real(double)
        default: return .null
        }
    }
    private static func validWaterKey(_ key: String) -> Bool { ["hydration", "hydrationImported"].contains(key) }
    private static func waterKey(_ args: [String: Any]) throws -> String {
        guard let key = args["key"] as? String, validWaterKey(key) else { throw InputError.missingArgument }
        return key
    }
}
