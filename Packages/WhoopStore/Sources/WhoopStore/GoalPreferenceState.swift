import Foundation
import GRDB

extension WhoopStore {
    /// The shared goal stores' property-list image, distinct from sensor inputs and derived analysis.
    public func goalPreferenceState() async throws -> Data? {
        try syncRead { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM goalPreferenceState WHERE id = 1")
        }
    }

    /// Publishes a whole reviewed change only while its source image is still current. An intervening
    /// writer causes a conflict rather than overwriting user input; SQLite errors leave the old row intact.
    public func commitGoalPreferenceState(expected: Data?, replacement: Data) async throws -> Bool {
        try syncWrite { db in
            let current = try Data.fetchOne(db, sql: "SELECT payload FROM goalPreferenceState WHERE id = 1")
            guard current == expected else { return false }
            try db.execute(sql: """
                INSERT INTO goalPreferenceState (id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [replacement])
            return true
        }
    }
}

extension WhoopStore {
    /// Applies database-backed goal settings to a disposable restore candidate before the archive swaps
    /// it into place. The callback sees the source backup's state, never the destination phone's goals.
    /// The connection checkpoints and closes before returning, so all writes and any legacy WAL data
    /// are in the main file before the caller copies it into place.
    public static func prepareRestoredGoalPreferenceState(at path: String,
        sealAndroidInputs: Bool = false,
        transform: (Data?) throws -> Data?) throws {
        let database = try DatabaseQueue(path: path)
        try UpstreamMigrationBridge.adopt(database)
        try makeMigrator().migrate(database)
        try database.write { db in
            if sealAndroidInputs { try sealAndroidJournalHydration(in: db); try sealAndroidInputLanes(in: db) }
            let previous = try Data.fetchOne(db, sql: "SELECT payload FROM goalPreferenceState WHERE id = 1")
            guard let replacement = try transform(previous), replacement != previous else { return }
            try db.execute(sql: """
                INSERT INTO goalPreferenceState (id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [replacement])
        }
        try database.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        try database.close()
    }
}
