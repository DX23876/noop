import Foundation
import WhoopStore

/// Settings › Data & Backup › Storage for Android: the same "where is the on-device space going" the iPhone's
/// `StorageView` shows for the health database, and the clean-up that folds the write-ahead log back into the
/// database file so the freed pages return to the phone.
///
/// Only the database is the core's to measure. The scratch copies an import leaves behind are files in the
/// platform's own cache folder, which the host reads and removes itself (file-system presentation).
enum CoreStorage {
    struct Report: Encodable, Equatable {
        /// The database with its `-wal` and `-shm` files, in bytes; absent for a store with no file.
        let db: Int64?
    }

    static func report(store: WhoopStore) async -> Report {
        Report(db: await store.databaseFileSizeBytes())
    }

    struct CleanUp: Encodable, Equatable {
        let db: Int64?
        /// False when SQLite could not checkpoint; the sizes are then the ones before.
        let checkpointed: Bool
    }

    /// Truncates the write-ahead log. Never touches a row.
    static func cleanUp(store: WhoopStore) async -> CleanUp {
        let done = (try? await store.checkpointWAL()) != nil
        return CleanUp(db: await store.databaseFileSizeBytes(), checkpointed: done)
    }

    static func run(_ op: String, _ args: [String: Any]) async -> String? {
        switch op {
        case "storage.report":
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            return CoreRead.json(await report(store: store))
        case "storage.cleanUp":
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            return CoreRead.json(await cleanUp(store: store))
        default:
            return nil
        }
    }
}
