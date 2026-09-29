import Foundation
import GRDB

/// Where a workout's stored `energyKcal` came from.
public enum WorkoutEnergySource: String, Sendable, Equatable {
    /// NOOP computed it: the live recorder, the post-sync rescore, the detector's backfill.
    case computed
    /// The wearer typed it, or kept a value in the manual sheet.
    case entered
}

/// A workout's natural key, as `workout` and `workoutEnergySource` share it.
public struct WorkoutKey: Hashable, Sendable {
    public let deviceId: String
    public let startTs: Int
    public let sport: String

    public init(deviceId: String, startTs: Int, sport: String) {
        self.deviceId = deviceId
        self.startTs = startTs
        self.sport = sport
    }
}

extension WhoopStore {

    /// Records where a workout's energy came from. Replaces any earlier entry for the same row.
    public func setWorkoutEnergySource(_ kind: WorkoutEnergySource, for key: WorkoutKey,
                                       at now: Int = Int(Date().timeIntervalSince1970)) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO workoutEnergySource (deviceId, startTs, sport, kind, updatedAtTs)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                    kind = excluded.kind, updatedAtTs = excluded.updatedAtTs
                """, arguments: [key.deviceId, key.startTs, key.sport, kind.rawValue, now])
        }
    }

    /// Forgets where a workout's energy came from, for a row that was deleted or re-keyed.
    public func clearWorkoutEnergySource(for key: WorkoutKey) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM workoutEnergySource WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [key.deviceId, key.startTs, key.sport])
        }
    }

    /// The recorded sources of one device's workouts starting in `[from, to]`.
    public nonisolated func workoutEnergySources(deviceId: String, from: Int,
                                                 to: Int) async throws -> [WorkoutKey: WorkoutEnergySource] {
        try await asyncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT startTs, sport, kind FROM workoutEnergySource
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                """, arguments: [deviceId, from, to])
            var out: [WorkoutKey: WorkoutEnergySource] = [:]
            for row in rows {
                guard let kind = WorkoutEnergySource(rawValue: row["kind"]) else { continue }
                out[WorkoutKey(deviceId: deviceId, startTs: row["startTs"], sport: row["sport"])] = kind
            }
            return out
        }
    }
}
