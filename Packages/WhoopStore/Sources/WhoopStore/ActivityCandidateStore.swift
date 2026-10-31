import Foundation
import GRDB

/// One stored activity-detection suggestion, as the daily pass found it (`ActivityCandidates` in
/// StrandAnalytics). Screens and notifications read these; nothing scores them. A rolling window: the pass
/// rewrites its recent days and drops rows older than `keepDays`, so a rule change never needs a rebuild of
/// history (fork decision 2026-10-31).
public struct ActivityCandidateRow: Equatable, Sendable {
    public var deviceId: String
    /// "walk" or "heartRate".
    public var track: String
    public var startTs: Int
    public var endTs: Int
    public var ruleVersion: String
    public var avgBpm: Int?
    public var peakBpm: Int?
    public var load: Double
    public var cadence: Int?
    public var locomotionShare: Double?
    /// The likely kinds, best first ("walk", "strength", …).
    public var kinds: [String]

    public init(deviceId: String, track: String, startTs: Int, endTs: Int, ruleVersion: String, avgBpm: Int?,
                peakBpm: Int?, load: Double, cadence: Int?, locomotionShare: Double?, kinds: [String]) {
        self.deviceId = deviceId
        self.track = track
        self.startTs = startTs
        self.endTs = endTs
        self.ruleVersion = ruleVersion
        self.avgBpm = avgBpm
        self.peakBpm = peakBpm
        self.load = load
        self.cadence = cadence
        self.locomotionShare = locomotionShare
        self.kinds = kinds
    }

    fileprivate static func decode(_ row: Row) -> ActivityCandidateRow {
        let kinds: String = row["kinds"]
        return ActivityCandidateRow(
            deviceId: row["deviceId"], track: row["track"], startTs: row["startTs"], endTs: row["endTs"],
            ruleVersion: row["ruleVersion"], avgBpm: row["avgBpm"], peakBpm: row["peakBpm"], load: row["load"],
            cadence: row["cadence"], locomotionShare: row["locomotionShare"],
            kinds: kinds.split(separator: ",").map(String.init))
    }
}

extension WhoopStore {
    public static let activityCandidateKeepDays = 30

    static func createActivityCandidateTable(_ db: Database) throws {
        try db.create(table: "activityCandidate") { t in
            t.column("deviceId", .text).notNull()
            t.column("track", .text).notNull()
            t.column("startTs", .integer).notNull()
            t.column("endTs", .integer).notNull()
            t.column("ruleVersion", .text).notNull()
            t.column("avgBpm", .integer)
            t.column("peakBpm", .integer)
            t.column("load", .double).notNull()
            t.column("cadence", .integer)
            t.column("locomotionShare", .double)
            t.column("kinds", .text).notNull()
            t.primaryKey(["deviceId", "track", "startTs"])
        }
    }

    /// Replaces every stored suggestion of `deviceId` starting in `[from, to)` with `rows`, and drops rows
    /// older than `activityCandidateKeepDays` before `to`, in one transaction.
    public func replaceActivityCandidates(deviceId: String, from: Int, to: Int,
                                          rows: [ActivityCandidateRow]) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM activityCandidate WHERE deviceId = ? AND startTs >= ? AND startTs < ?",
                           arguments: [deviceId, from, to])
            try db.execute(sql: "DELETE FROM activityCandidate WHERE deviceId = ? AND startTs < ?",
                           arguments: [deviceId, to - Self.activityCandidateKeepDays * 86_400])
            for r in rows where r.deviceId == deviceId && r.startTs >= from && r.startTs < to && r.endTs > r.startTs {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO activityCandidate
                      (deviceId, track, startTs, endTs, ruleVersion, avgBpm, peakBpm, load, cadence,
                       locomotionShare, kinds)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.deviceId, r.track, r.startTs, r.endTs, r.ruleVersion, r.avgBpm, r.peakBpm,
                                     r.load.isFinite ? r.load : 0, r.cadence, r.locomotionShare,
                                     r.kinds.joined(separator: ",")])
            }
        }
    }

    /// Stored suggestions of `deviceId` overlapping `[from, to)`, oldest first.
    public nonisolated func activityCandidates(deviceId: String, from: Int, to: Int) async throws
        -> [ActivityCandidateRow] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM activityCandidate WHERE deviceId = ? AND startTs < ? AND endTs > ?
                ORDER BY startTs, track
                """, arguments: [deviceId, to, from]).map(ActivityCandidateRow.decode)
        }
    }
}
