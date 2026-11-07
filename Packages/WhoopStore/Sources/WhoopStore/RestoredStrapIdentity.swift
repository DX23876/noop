import Foundation
import GRDB

/// A backup carries the registry of the install that wrote it, including the Bluetooth identity of the strap worn
/// then. Restored as it is, that identity pins the app to the old strap and the one on the wrist is ignored, however
/// long ago the old one was retired or removed from the phone's Bluetooth list. So a restore settles which strap the
/// restored registry follows before the store is swapped in.
extension WhoopStore {
    /// The WHOOP the install is following: its Bluetooth identity and the model label that goes with it.
    public struct FollowedStrap: Equatable, Sendable {
        public let peripheralId: String
        public let model: String
        public init(peripheralId: String, model: String) { self.peripheralId = peripheralId; self.model = model }
    }

    private static let whoopRow = "(id = 'my-whoop' OR brand = 'WHOOP' COLLATE NOCASE)"

    /// The active WHOOP of the store at `path` when it has adopted a strap; nil for anything else, including a store
    /// that cannot be read, so that reading it can never stop a restore.
    public static func followedStrap(inStoreAt path: String) -> FollowedStrap? {
        var configuration = Configuration()
        configuration.readonly = true
        guard FileManager.default.fileExists(atPath: path),
              let database = try? DatabaseQueue(path: path, configuration: configuration) else { return nil }
        defer { try? database.close() }
        return try? database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT peripheralId, model FROM pairedDevice WHERE status = 'active' AND \(whoopRow) LIMIT 1
                """), let peripheralId: String = row["peripheralId"], !peripheralId.isEmpty else { return nil }
            return FollowedStrap(peripheralId: peripheralId, model: row["model"] ?? "")
        }
    }

    /// Settles the restored registry at `path`, a disposable restore candidate.
    ///
    /// With a strap in use on this phone, that strap stays: its own restored row becomes active, or else the restored
    /// active WHOOP takes over its identity and model, which keeps the history and the new strap under one row. On a
    /// phone following no strap, a lone restored WHOOP forgets its old identity and adopts the first strap it meets.
    /// Several restored WHOOPs keep theirs: only the wearer can say which one is on the wrist. Either way exactly one
    /// device is active afterwards (`DeviceRegistryStore.keepOneActive`), the strap this phone follows when it has one.
    public static func keepFollowedStrap(_ followed: FollowedStrap?, inRestoredStoreAt path: String) throws {
        let database = try DatabaseQueue(path: path)
        try database.write { db in
            // An Android backup lands on a store that seeded an active `my-whoop`, so the restored rows can hold two
            // active devices; one is settled first, and the identity below goes to that one.
            guard let followed else {
                try DeviceRegistryStore.keepOneActive(db)
                let ids = try String.fetchAll(db, sql: """
                    SELECT id FROM pairedDevice WHERE status != 'archived' AND \(whoopRow)
                    """)
                guard ids.count == 1 else { return }
                try db.execute(sql: "UPDATE pairedDevice SET peripheralId = NULL WHERE id = ?", arguments: [ids[0]])
                return
            }
            if let known = try String.fetchOne(db, sql: """
                SELECT id FROM pairedDevice WHERE peripheralId = ? COLLATE NOCASE AND \(whoopRow) LIMIT 1
                """, arguments: [followed.peripheralId]) {
                try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
                try db.execute(sql: "UPDATE pairedDevice SET status = 'active' WHERE id = ?", arguments: [known])
                try DeviceRegistryStore.keepOneActive(db, preferring: known)
                return
            }
            let preferred = try String.fetchOne(db, sql: """
                SELECT id FROM pairedDevice WHERE status = 'active' AND \(whoopRow)
                ORDER BY (id = 'my-whoop'), (COALESCE(peripheralId, '') = ''), lastSeenAt DESC LIMIT 1
                """)
            guard let active = try DeviceRegistryStore.keepOneActive(db, preferring: preferred),
                  active == preferred else { return }
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = ?, model = ? WHERE id = ?",
                           arguments: [followed.peripheralId, followed.model, active])
        }
        _ = try database.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        try database.close()
    }
}
