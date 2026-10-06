import Foundation
import GRDB

extension WhoopStore {
    /// Latest manual reading per civil day; imported Health values never enter the outbound loop.
    public func healthBodyMeasurements(kind: String, from: String, to: String) async throws -> [MetricPoint] {
        try syncRead { db in
            let rows: [Row]
            if kind == "weight" {
                rows = try Row.fetchAll(db, sql: """
                    SELECT day, weightKg AS value FROM bodyWeightEntry
                    WHERE deviceId = ? AND source = 'manual' AND day >= ? AND day <= ?
                    ORDER BY takenAt, id
                    """, arguments: [Self.noopWeightSourceId, from, to])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT day, value FROM labMarker WHERE markerKey = 'waist'
                    AND source IN ('manual', 'profile') AND day >= ? AND day <= ? ORDER BY takenAt, id
                    """, arguments: [from, to])
            }
            var latest: [String: Double] = [:]
            for row in rows {
                let day: String = row["day"]
                if let value: Double = row["value"] { latest[day] = value }
            }
            return latest.keys.sorted().map { .init(day: $0, key: kind, value: latest[$0]!) }
        }
    }
}
