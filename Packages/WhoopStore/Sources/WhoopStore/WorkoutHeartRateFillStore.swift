import Foundation
import GRDB

/// The heart rate NOOP filled into one workout whose source brought none (v73).
///
/// Laid over the stored row when it is read, never written into it: the row's columns belong to its
/// source and are rewritten on every sync.
public struct WorkoutHeartRateFillRow: Equatable, Sendable {
    public let key: WorkoutKey
    public let avgHr: Int
    public let maxHr: Int
    public let strain: Double?
    /// "band" or "watch".
    public let hrSource: String
    public let restingHrUsed: Double?
    public let coveredMinutes: Int
    public let possibleMinutes: Int
    public let updatedAtTs: Int

    public init(key: WorkoutKey, avgHr: Int, maxHr: Int, strain: Double?, hrSource: String,
                restingHrUsed: Double?, coveredMinutes: Int, possibleMinutes: Int, updatedAtTs: Int) {
        self.key = key; self.avgHr = avgHr; self.maxHr = maxHr; self.strain = strain
        self.hrSource = hrSource; self.restingHrUsed = restingHrUsed
        self.coveredMinutes = coveredMinutes; self.possibleMinutes = possibleMinutes
        self.updatedAtTs = updatedAtTs
    }
}

extension WhoopStore {

    /// Replaces the fills of `keys`: each key gets its row from `rows`, and a key without one loses any
    /// fill it had (its heart rate no longer covers the session). Keys outside `keys` are untouched.
    public func replaceWorkoutHeartRateFills(_ rows: [WorkoutHeartRateFillRow],
                                             keys: [WorkoutKey]) async throws {
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        try syncWrite { db in
            for key in Set(keys).union(byKey.keys) {
                guard let r = byKey[key] else {
                    try db.execute(sql: """
                        DELETE FROM workoutHeartRateFill WHERE deviceId = ? AND startTs = ? AND sport = ?
                        """, arguments: [key.deviceId, key.startTs, key.sport])
                    continue
                }
                guard r.avgHr > 0, r.maxHr > 0, r.strain.map({ $0.isFinite && $0 >= 0 }) ?? true else { continue }
                try db.execute(sql: """
                    INSERT INTO workoutHeartRateFill
                      (deviceId, startTs, sport, avgHr, maxHr, strain, hrSource, restingHrUsed,
                       coveredMinutes, possibleMinutes, updatedAtTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                      avgHr = excluded.avgHr, maxHr = excluded.maxHr, strain = excluded.strain,
                      hrSource = excluded.hrSource, restingHrUsed = excluded.restingHrUsed,
                      coveredMinutes = excluded.coveredMinutes, possibleMinutes = excluded.possibleMinutes,
                      updatedAtTs = excluded.updatedAtTs
                    """, arguments: [key.deviceId, key.startTs, key.sport, r.avgHr, r.maxHr, r.strain,
                                      r.hrSource, r.restingHrUsed, r.coveredMinutes, r.possibleMinutes,
                                      r.updatedAtTs])
            }
        }
    }

    /// The fills of one source's workouts starting in `[from, to]`.
    public nonisolated func workoutHeartRateFills(deviceId: String, from: Int,
                                                  to: Int) async throws -> [WorkoutKey: WorkoutHeartRateFillRow] {
        try await asyncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM workoutHeartRateFill WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                """, arguments: [deviceId, from, to])
            var out: [WorkoutKey: WorkoutHeartRateFillRow] = [:]
            for row in rows {
                let key = WorkoutKey(deviceId: row["deviceId"], startTs: row["startTs"], sport: row["sport"])
                out[key] = WorkoutHeartRateFillRow(
                    key: key, avgHr: row["avgHr"], maxHr: row["maxHr"], strain: row["strain"],
                    hrSource: row["hrSource"], restingHrUsed: row["restingHrUsed"],
                    coveredMinutes: row["coveredMinutes"], possibleMinutes: row["possibleMinutes"],
                    updatedAtTs: row["updatedAtTs"])
            }
            return out
        }
    }

    /// Drops the cardio-load ledger rows of sessions starting in `[from, to]` that were priced without a
    /// heart-rate trace (`hrSource` "none", or "avg_hr" for an average-only estimate), so the next pricing
    /// pass computes them again now that a trace has arrived. Rows priced from a trace are kept. Returns
    /// the rows removed.
    @discardableResult
    public func dropUntracedTrainingSessionLoads(from: Int, to: Int) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM trainingSessionLoad
                WHERE startTs >= ? AND startTs <= ? AND hrSource IN ('none', 'avg_hr')
                """, arguments: [from, to])
            return db.changesCount
        }
    }
}
