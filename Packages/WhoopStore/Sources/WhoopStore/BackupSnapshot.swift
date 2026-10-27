import Foundation
import GRDB

extension WhoopStore {
    /// Copies one committed SQLite snapshot, including WAL data, into a fresh standalone file. Goal
    /// settings are read from that exact copy so the archive's database and settings cannot disagree.
    /// The caller owns the destination and must keep it outside the live store's paths.
    /// Runs outside the store actor: copying a large history must not hold the collector's normal
    /// store executor. GRDB's reader snapshot remains isolated from concurrent committed writes.
    public nonisolated func writeBackupSnapshot(to path: String) async throws -> Data? {
        let destination = try DatabaseQueue(path: path)
        try dbWriter.backup(to: destination)
        let goals = try await destination.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM goalPreferenceState WHERE id = 1")
        }
        try destination.close()
        return goals
    }
}
