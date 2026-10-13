import Foundation
import GRDB

/// The height one workout climbed and descended (v78), laid over the row when it is read.
///
/// `source` says who counted it: `barometer` for a workout NOOP recorded itself (OpenTracks' method),
/// `apple-health` for the total Apple Health stored with a workout, `file` for an imported activity file.
/// `descentM` is nil when the source reported only the climb.
public struct WorkoutElevationRow: Equatable, Sendable {
    public let key: WorkoutKey
    public let ascentM: Double
    public let descentM: Double?
    public let source: String
    public let updatedAtTs: Int

    public init(key: WorkoutKey, ascentM: Double, descentM: Double?, source: String, updatedAtTs: Int) {
        self.key = key; self.ascentM = ascentM; self.descentM = descentM
        self.source = source; self.updatedAtTs = updatedAtTs
    }

    /// A row worth storing: finite, non-negative heights.
    public var isValid: Bool {
        ascentM.isFinite && ascentM >= 0 && (descentM.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

/// The `source` values a `WorkoutElevationRow` carries.
public enum WorkoutElevationSource {
    /// Counted by NOOP from the phone's barometer during a recorded workout.
    public static let barometer = "barometer"
    /// The total Apple Health stored with the workout (`HKMetadataKeyElevationAscended`).
    public static let appleHealth = "apple-health"
    /// Summed from an imported GPX, TCX or FIT file.
    public static let file = "file"
}

extension WorkoutElevationRow {

    /// The one place a workout's elevation is resolved. Candidates are the entries on the row's own start
    /// and sport (whatever device id they were stored under); the one whose source fits the row's own
    /// source wins, then NOOP's barometer, Apple Health and a file in that order. A twin recorded by another
    /// source at the same instant is the same session, so its climb is the session's climb.
    public static func resolve(startTs: Int, sport: String, rowSource: String,
                               in rows: [WorkoutKey: WorkoutElevationRow]) -> WorkoutElevationRow? {
        let candidates = rows.values.filter { $0.key.startTs == startTs && $0.key.sport == sport && $0.isValid }
        guard !candidates.isEmpty else { return nil }
        let own: String = switch rowSource {
        case WorkoutElevationSource.appleHealth: WorkoutElevationSource.appleHealth
        case "activity-file": WorkoutElevationSource.file
        default: WorkoutElevationSource.barometer
        }
        let order = [own, WorkoutElevationSource.barometer, WorkoutElevationSource.appleHealth,
                     WorkoutElevationSource.file]
        return candidates.min {
            let a = order.firstIndex(of: $0.source) ?? order.count
            let b = order.firstIndex(of: $1.source) ?? order.count
            return (a, $0.key.deviceId) < (b, $1.key.deviceId)
        }
    }
}

extension WhoopStore {

    /// Upserts elevation rows by workout key. Invalid rows are skipped; other keys are untouched.
    public func upsertWorkoutElevations(_ rows: [WorkoutElevationRow]) async throws {
        try syncWrite { db in
            for r in rows where r.isValid {
                try db.execute(sql: """
                    INSERT INTO workoutElevation (deviceId, startTs, sport, ascentM, descentM, source, updatedAtTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                      ascentM = excluded.ascentM, descentM = excluded.descentM,
                      source = excluded.source, updatedAtTs = excluded.updatedAtTs
                    """, arguments: [r.key.deviceId, r.key.startTs, r.key.sport, r.ascentM, r.descentM,
                                      r.source, r.updatedAtTs])
            }
        }
    }

    /// Removes the elevation of one workout (the workout itself was deleted).
    public func deleteWorkoutElevation(_ key: WorkoutKey) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workoutElevation WHERE deviceId = ? AND startTs = ? AND sport = ?",
                           arguments: [key.deviceId, key.startTs, key.sport])
        }
    }

    /// The elevation of every workout starting in `[from, to]`, across sources.
    public nonisolated func workoutElevations(from: Int, to: Int) async throws -> [WorkoutKey: WorkoutElevationRow] {
        try await asyncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM workoutElevation WHERE startTs >= ? AND startTs <= ?
                """, arguments: [from, to])
            var out: [WorkoutKey: WorkoutElevationRow] = [:]
            for row in rows {
                let key = WorkoutKey(deviceId: row["deviceId"], startTs: row["startTs"], sport: row["sport"])
                out[key] = WorkoutElevationRow(key: key, ascentM: row["ascentM"], descentM: row["descentM"],
                                               source: row["source"], updatedAtTs: row["updatedAtTs"])
            }
            return out
        }
    }
}
