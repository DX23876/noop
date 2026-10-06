import Foundation
import GRDB

extension WhoopStore {
    /// Fold the full earlier recording history in one database snapshot, retaining one payload at a time.
    /// No arbitrary history limit may turn a missed older record into a claimed personal best.
    public func reduceWorkoutRecordingPayloads<T: Sendable>(sport: String, before startTs: Int,
        initial: T, combine: @escaping @Sendable (T, String) throws -> T) async throws -> T {
        try await asyncRead { db in
            let cursor = try String.fetchCursor(db, sql: """
                SELECT payloadJSON FROM workoutRecording WHERE sport = ? AND startTs < ?
                """, arguments: [sport, startTs])
            var result = initial
            while let payload = try cursor.next() { result = try combine(result, payload) }
            return result
        }
    }

    /// A completed recording is acknowledged only after its row, evidence and energy provenance commit.
    public func saveWorkoutRecording(_ row: WorkoutRow, deviceId: String, payloadJSON: String,
                                     computedEnergy: Bool = true) async throws {
        try syncWrite { db in
            try Self.writeWorkout(row, deviceId: deviceId, in: db)
            try db.execute(sql: """
                INSERT INTO workoutRecording (deviceId, startTs, sport, payloadJSON) VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET payloadJSON = excluded.payloadJSON
                """, arguments: [deviceId, row.startTs, row.sport, payloadJSON])
            if computedEnergy, (row.energyKcal ?? 0) > 0 {
                try db.execute(sql: """
                    INSERT INTO workoutEnergySource (deviceId, startTs, sport, kind, updatedAtTs)
                    VALUES (?, ?, ?, 'computed', ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        kind = excluded.kind, updatedAtTs = excluded.updatedAtTs
                    """, arguments: [deviceId, row.startTs, row.sport, row.endTs])
            }
        }
    }

    /// Source-scoped evidence; a natural-key collision in an import is not this recording.
    public func workoutRecording(for key: WorkoutKey) async throws -> String? {
        try await asyncRead { db in
            try String.fetchOne(db, sql: """
                SELECT payloadJSON FROM workoutRecording WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [key.deviceId, key.startTs, key.sport])
        }
    }

    /// Carry immutable original evidence when a correction changes the lookup key.
    public func copyWorkoutRecording(from old: WorkoutKey, to new: WorkoutKey) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO workoutRecording (deviceId, startTs, sport, payloadJSON)
                SELECT ?, ?, ?, payloadJSON FROM workoutRecording
                WHERE deviceId = ? AND startTs = ? AND sport = ?
                ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET payloadJSON = excluded.payloadJSON
                """, arguments: [new.deviceId, new.startTs, new.sport, old.deviceId, old.startTs, old.sport])
        }
    }
}
