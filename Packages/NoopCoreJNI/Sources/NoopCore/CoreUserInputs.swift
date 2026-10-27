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
            case "input.waterDeleteSeries":
                _ = try await store.deleteMetricSeries(deviceId: "hydration", key: waterKey(args))
            default: return #"{"error":"unknownInputOperation"}"#
            }
            return #"{"ok":true}"#
        } catch { return #"{"error":"inputUnavailable"}"# }
    }

    private enum InputError: Error { case missingArgument, outsideWindow }
    private static func validWaterKey(_ key: String) -> Bool { ["hydration", "hydrationImported"].contains(key) }
    private static func waterKey(_ args: [String: Any]) throws -> String {
        guard let key = args["key"] as? String, validWaterKey(key) else { throw InputError.missingArgument }
        return key
    }
}
