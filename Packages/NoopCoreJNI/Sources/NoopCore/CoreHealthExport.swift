import Foundation
import WhoopStore

/// Which records a Health Connect export must actually write: Apple's `HealthSampleWriter.save` ledger
/// (`healthExportVersion`), given to Android. Each record carries a fingerprint of what it says; one whose
/// fingerprint matches the last committed write is left alone, and a changed one gets a revision above every
/// earlier one, so Health Connect replaces it. Until 2026-11-26 the Android writer rewrote every vital of its
/// 60-day window on each pass, about 190 records every 15 minutes, with a fresh version that forced each one in.
enum CoreHealthExport {
    /// Ledger ids carry this prefix so Android's records never meet Apple Health's in the shared table.
    static let idPrefix = "hc|"

    struct Plan: Encodable {
        struct Version: Encodable { let id: String; let revision: Int; let needsSave: Bool }
        let versions: [Version]
    }

    /// `{"items":[{"id":…,"fingerprint":…}]}` → `{"versions":[{"id":…,"revision":…,"needsSave":…}]}`, in order.
    static func plan(store: WhoopStore, args: [String: Any]) async -> String {
        let items = (args["items"] as? [[String: Any]] ?? []).compactMap { item -> (id: String, fingerprint: String)? in
            guard let id = item["id"] as? String, !id.isEmpty, let fingerprint = item["fingerprint"] as? String
            else { return nil }
            return (idPrefix + id, fingerprint)
        }
        guard !items.isEmpty else { return #"{"versions":[]}"# }
        do {
            // In seconds, the unit Android's Health Connect versions have always used: an older build that a
            // tester goes back to must still be able to replace what this one wrote.
            let versions = try await store.planHealthExports(items, versionFloor: Int(Date().timeIntervalSince1970))
            return CoreRead.json(Plan(versions: versions.map {
                .init(id: String($0.id.dropFirst(idPrefix.count)), revision: $0.revision, needsSave: $0.needsSave)
            }))
        } catch {
            return #"{"error":"store"}"#
        }
    }

    /// `{"versions":[{"id":…,"revision":…}]}`: the records Health Connect accepted. Only an exact revision is
    /// marked, so a newer plan made meanwhile stays pending.
    static func commit(store: WhoopStore, args: [String: Any]) async -> String {
        let versions = (args["versions"] as? [[String: Any]] ?? []).compactMap { item -> HealthSyncState.ExportVersion? in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let revision = (item["revision"] as? NSNumber)?.intValue else { return nil }
            return .init(id: idPrefix + id, revision: revision, needsSave: false)
        }
        guard !versions.isEmpty else { return #"{"ok":true}"# }
        do {
            try await store.commitHealthExports(versions)
            return #"{"ok":true}"#
        } catch {
            return #"{"ok":false}"#
        }
    }

    /// `{"ids":[…]}`: records deleted from Health Connect, so a later export with the same content writes them again.
    static func invalidate(store: WhoopStore, args: [String: Any]) async -> String {
        let ids = (args["ids"] as? [String] ?? []).filter { !$0.isEmpty }.map { idPrefix + $0 }
        guard !ids.isEmpty else { return #"{"ok":true}"# }
        do {
            try await store.invalidateHealthExports(ids: ids)
            return #"{"ok":true}"#
        } catch {
            return #"{"ok":false}"#
        }
    }
}
