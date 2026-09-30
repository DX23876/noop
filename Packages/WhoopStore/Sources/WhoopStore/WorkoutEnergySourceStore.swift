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

    /// Reprice one unmarked legacy manual row without rewriting its other fields. The value check
    /// protects an edit made while the migration was computing, and the marker shares the transaction.
    public func correctLegacyWorkoutEnergy(for key: WorkoutKey, matching oldKcal: Double,
                                           to newKcal: Double) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE workout SET energyKcal = ?
                WHERE deviceId = ? AND startTs = ? AND sport = ? AND source = 'manual'
                  AND energyKcal = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM workoutEnergySource e
                    WHERE e.deviceId = workout.deviceId AND e.startTs = workout.startTs
                      AND e.sport = workout.sport)
                """, arguments: [newKcal, key.deviceId, key.startTs, key.sport, oldKcal])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: """
                INSERT INTO workoutEnergySource (deviceId, startTs, sport, kind, updatedAtTs)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [key.deviceId, key.startTs, key.sport,
                                  WorkoutEnergySource.computed.rawValue,
                                  Int(Date().timeIntervalSince1970)])
            return true
        }
    }

    /// Reprice one manual row NOOP already computed, when the price it holds came from wrong inputs.
    /// Only a row still marked `computed` and still holding `oldKcal` changes: one the wearer edited
    /// or re-entered in the meantime keeps its figure. The marker's timestamp moves with the value.
    public func repriceComputedWorkoutEnergy(for key: WorkoutKey, matching oldKcal: Double,
                                             to newKcal: Double) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE workout SET energyKcal = ?
                WHERE deviceId = ? AND startTs = ? AND sport = ? AND source = 'manual'
                  AND energyKcal = ?
                  AND EXISTS (
                    SELECT 1 FROM workoutEnergySource e
                    WHERE e.deviceId = workout.deviceId AND e.startTs = workout.startTs
                      AND e.sport = workout.sport AND e.kind = ?)
                """, arguments: [newKcal, key.deviceId, key.startTs, key.sport, oldKcal,
                                  WorkoutEnergySource.computed.rawValue])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: """
                UPDATE workoutEnergySource SET updatedAtTs = ?
                WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [Int(Date().timeIntervalSince1970), key.deviceId, key.startTs, key.sport])
            return true
        }
    }

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
