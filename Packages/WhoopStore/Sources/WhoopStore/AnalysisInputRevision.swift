import Foundation
import GRDB

/// The persisted raw-input version intersecting one analysis window.
public struct AnalysisInputRevision: Equatable, Sendable {
    public let inputRevision: Int
    public let deviceRevision: Int

    public init(inputRevision: Int, deviceRevision: Int) {
        self.inputRevision = inputRevision
        self.deviceRevision = deviceRevision
    }
}

extension WhoopStore {
    /// UTC day number used by `analysisInputRevision`. Sensor timestamps are Unix seconds and therefore
    /// non-negative in every supported input, but floor division keeps the helper correct for fixtures.
    static func utcDay(_ timestamp: Int) -> Int {
        if timestamp >= 0 { return timestamp / 86_400 }
        return (timestamp - 86_399) / 86_400
    }

    /// Stamp the exact UTC buckets touched by a scoring-relevant mutation. The caller must already be in
    /// the mutation transaction and must call this only when at least one row actually changed.
    static func markAnalysisInputsChanged(_ db: Database, deviceId: String,
                                          timestamps: some Sequence<Int>) throws {
        let buckets = Set(timestamps.map(utcDay))
        guard !buckets.isEmpty else { return }
        let revision = try bumpSensorWriteSeq(db)
        let stmt = try db.cachedStatement(sql: """
            INSERT INTO analysisInputRevision (deviceId, utcDay, revision) VALUES (?, ?, ?)
            ON CONFLICT(deviceId, utcDay) DO UPDATE SET revision = MAX(revision, excluded.revision)
            """)
        for bucket in buckets {
            try stmt.execute(arguments: [deviceId, bucket, revision])
        }
    }

    /// Conservatively invalidate every cached day for a source after an unbounded delete/repoint.
    static func markAnalysisDeviceChanged(_ db: Database, deviceId: String) throws {
        let revision = try bumpSensorWriteSeq(db)
        try db.execute(sql: """
            INSERT INTO analysisDeviceRevision (deviceId, revision) VALUES (?, ?)
            ON CONFLICT(deviceId) DO UPDATE SET revision = MAX(revision, excluded.revision)
            """, arguments: [deviceId, revision])
    }

    /// Revisions for the inclusive Unix-second analysis window. One indexed MAX over a handful of UTC
    /// rows replaces per-stream COUNT/MAX probes over millions of samples.
    public nonisolated func analysisInputRevision(deviceId: String, from: Int, to: Int) async throws
        -> AnalysisInputRevision {
        let lo = WhoopStore.utcDay(min(from, to))
        let hi = WhoopStore.utcDay(max(from, to))
        return try await asyncRead { db in
            let input = try Int.fetchOne(db, sql: """
                SELECT MAX(revision) FROM analysisInputRevision
                WHERE deviceId = ? AND utcDay >= ? AND utcDay <= ?
                """, arguments: [deviceId, lo, hi]) ?? 0
            let device = try Int.fetchOne(db, sql: """
                SELECT revision FROM analysisDeviceRevision WHERE deviceId = ?
                """, arguments: [deviceId]) ?? 0
            return AnalysisInputRevision(inputRevision: input, deviceRevision: device)
        }
    }
}
