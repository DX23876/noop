import Foundation
import GRDB

/// One canonical training session's cardio load, as it was computed and by what (v70).
///
/// A row with `trimp == nil` records that the session's heart rate could not price it, so the answer is
/// not recomputed on every read. `hrSource` is then `"none"`.
public struct TrainingSessionLoadRow: Equatable, Codable, Sendable {
    public let sessionId: String
    public let method: String
    public let methodVersion: Int
    public let startTs: Int
    public let endTs: Int
    public let trimp: Double?
    public let effort: Double?
    public let hrSource: String
    public let coveredMinutes: Int
    public let possibleMinutes: Int
    public let hrmaxUsed: Double
    public let restingHrUsed: Double?
    public let inputFingerprint: String
    public let computedAtTs: Int

    public init(sessionId: String, method: String, methodVersion: Int, startTs: Int, endTs: Int,
                trimp: Double?, effort: Double?, hrSource: String, coveredMinutes: Int, possibleMinutes: Int,
                hrmaxUsed: Double, restingHrUsed: Double?, inputFingerprint: String, computedAtTs: Int) {
        self.sessionId = sessionId; self.method = method; self.methodVersion = methodVersion
        self.startTs = startTs; self.endTs = endTs; self.trimp = trimp; self.effort = effort
        self.hrSource = hrSource; self.coveredMinutes = coveredMinutes; self.possibleMinutes = possibleMinutes
        self.hrmaxUsed = hrmaxUsed; self.restingHrUsed = restingHrUsed
        self.inputFingerprint = inputFingerprint; self.computedAtTs = computedAtTs
    }

    fileprivate init(row: Row) {
        self.init(sessionId: row["sessionId"], method: row["method"], methodVersion: row["methodVersion"],
                  startTs: row["startTs"], endTs: row["endTs"], trimp: row["trimp"], effort: row["effort"],
                  hrSource: row["hrSource"], coveredMinutes: row["coveredMinutes"],
                  possibleMinutes: row["possibleMinutes"], hrmaxUsed: row["hrmaxUsed"],
                  restingHrUsed: row["restingHrUsed"], inputFingerprint: row["inputFingerprint"],
                  computedAtTs: row["computedAtTs"])
    }
}

extension WhoopStore {
    /// Insert or replace rows, one transaction for the whole batch.
    public func upsertTrainingSessionLoads(_ rows: [TrainingSessionLoadRow]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO trainingSessionLoad
                      (sessionId, method, methodVersion, startTs, endTs, trimp, effort, hrSource,
                       coveredMinutes, possibleMinutes, hrmaxUsed, restingHrUsed, inputFingerprint, computedAtTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(sessionId, method, methodVersion) DO UPDATE SET
                      startTs=excluded.startTs, endTs=excluded.endTs, trimp=excluded.trimp,
                      effort=excluded.effort, hrSource=excluded.hrSource,
                      coveredMinutes=excluded.coveredMinutes, possibleMinutes=excluded.possibleMinutes,
                      hrmaxUsed=excluded.hrmaxUsed, restingHrUsed=excluded.restingHrUsed,
                      inputFingerprint=excluded.inputFingerprint, computedAtTs=excluded.computedAtTs
                    """, arguments: [r.sessionId, r.method, r.methodVersion, r.startTs, r.endTs, r.trimp,
                                      r.effort, r.hrSource, r.coveredMinutes, r.possibleMinutes, r.hrmaxUsed,
                                      r.restingHrUsed, r.inputFingerprint, r.computedAtTs])
            }
        }
    }

    /// The rows for a set of sessions under one method version, keyed by session id.
    public func trainingSessionLoads(sessionIds: [String], method: String,
                                     methodVersion: Int) async throws -> [String: TrainingSessionLoadRow] {
        guard !sessionIds.isEmpty else { return [:] }
        return try syncRead { db in
            var result: [String: TrainingSessionLoadRow] = [:]
            // SQLite caps bound parameters; read in chunks well under the limit.
            let unique = Array(Set(sessionIds))
            for start in stride(from: 0, to: unique.count, by: 500) {
                let chunk = Array(unique[start..<min(start + 500, unique.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM trainingSessionLoad
                    WHERE method = ? AND methodVersion = ? AND sessionId IN (\(marks))
                    """, arguments: StatementArguments([method, methodVersion] as [DatabaseValueConvertible])
                        + StatementArguments(chunk))
                for row in rows {
                    let parsed = TrainingSessionLoadRow(row: row)
                    result[parsed.sessionId] = parsed
                }
            }
            return result
        }
    }

    /// Every row of one method version whose session started in `[from, to]`, oldest first.
    public func trainingSessionLoads(from: Int, to: Int, method: String,
                                     methodVersion: Int) async throws -> [TrainingSessionLoadRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM trainingSessionLoad
                WHERE method = ? AND methodVersion = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs
                """, arguments: [method, methodVersion, from, to]).map(TrainingSessionLoadRow.init(row:))
        }
    }
}
