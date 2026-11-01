import Foundation
import StrandCore
import StrandImport
import WhoopStore

/// Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`, decision 8): a file the wearer
/// picked, parsed by `StrandImport` and written into the core's store by the importers the Apple apps use
/// (`WhoopImporter`, `AppleHealthImport`, `XiaomiImporter`, `WearableImporter`), so Android reads a file exactly as
/// iOS does. The Android app copies the picked document to `path` first.
enum CoreImport {
    struct Wire: Encodable {
        let source: String
        let recordCount: Int
        let earliest: String?
        let latest: String?
        let counts: [String: Int]
        let skippedSpans: Int
    }

    static func run(kind: String, path: String, deviceId: String, store: WhoopStore) async -> String {
        let url = URL(fileURLWithPath: path)
        do {
            let summary: ImportSummary
            switch kind {
            case "whoop": summary = try await WhoopImporter.importExport(url: url, into: store, deviceId: deviceId)
            case "appleHealth": summary = try await AppleHealthImport.importExport(url: url, into: store, deviceId: deviceId)
            case "xiaomi": summary = try await XiaomiImporter.importExport(url: url, into: store, deviceId: deviceId)
            case "wearable": summary = try await WearableImporter.importExport(url: url, into: store).summary
            default: return #"{"error":"unknownKind"}"#
            }
            try? await store.checkpointWAL()
            return CoreRead.json(Wire(source: summary.sourceKind.rawValue, recordCount: summary.recordCount,
                                      earliest: summary.earliest.map(day), latest: summary.latest.map(day),
                                      counts: summary.countsByCategory, skippedSpans: summary.skippedSpans))
        } catch {
            return CoreRead.json(["error": "importFailed", "detail": String(describing: error)])
        }
    }

    private static func day(_ date: Date) -> String { StoreReader.localDayKey(date) }
}
