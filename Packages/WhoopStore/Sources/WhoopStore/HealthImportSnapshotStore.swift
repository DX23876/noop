import Foundation
import GRDB

extension WhoopStore {
    /// Commit a complete, successfully-read daily window without letting sparse historical body rows
    /// replace unqueried activity/vitals. Missing points inside each authoritative window are cleared.
    public func replaceHealthDailySnapshot(appleRows: [AppleDaily], metrics: [DailyMetric], points: [MetricPoint],
        deviceId: String, from: String, to: String, bodyFrom: String, bodyTo: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM appleDaily WHERE deviceId = ? AND day >= ? AND day <= ?", arguments: [deviceId, from, to])
            try db.execute(sql: "DELETE FROM dailyMetric WHERE deviceId = ? AND day >= ? AND day <= ?", arguments: [deviceId, from, to])
            // Sparse history only owns the weight column, not the rest of this wide table.
            try db.execute(sql: "UPDATE appleDaily SET weightKg = NULL WHERE deviceId = ? AND day >= ? AND day <= ?", arguments: [deviceId, bodyFrom, bodyTo])
            for row in appleRows {
                if row.day >= from && row.day <= to {
                    try db.execute(sql: """
                        INSERT INTO appleDaily(deviceId, day, steps, activeKcal, basalKcal, vo2max, avgHr, maxHr, walkingHr, weightKg)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [deviceId, row.day, row.steps, row.activeKcal, row.basalKcal, row.vo2max, row.avgHr, row.maxHr, row.walkingHr, row.weightKg])
                } else if row.day >= bodyFrom && row.day <= bodyTo, let weight = row.weightKg {
                    try db.execute(sql: """
                        INSERT INTO appleDaily(deviceId, day, weightKg) VALUES (?, ?, ?)
                        ON CONFLICT(deviceId, day) DO UPDATE SET weightKg = excluded.weightKg
                        """, arguments: [deviceId, row.day, weight])
                }
            }
            _ = try Self.upsertDailyMetrics(metrics.filter { $0.day >= from && $0.day <= to }, deviceId: deviceId, in: db)
            let bodyKeys = ["weight", "body_fat", "lean_mass", "bmi"]
            let dailyKeys = ["resting_hr", "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "walking_hr", "steps", "active_kcal", "basal_kcal", "vo2max", "asleep_min", "deep_min", "rem_min", "core_min", "awake_min", "in_bed_min"]
            for (keys, lo, hi) in [(bodyKeys, bodyFrom, bodyTo), (dailyKeys, from, to)] {
                var arguments: [DatabaseValueConvertible?] = [deviceId, lo, hi]
                arguments.append(contentsOf: keys)
                try db.execute(sql: "DELETE FROM metricSeries WHERE deviceId = ? AND day >= ? AND day <= ? AND key IN (\(Array(repeating: "?", count: keys.count).joined(separator: ",")))", arguments: StatementArguments(arguments))
            }
            _ = try Self.upsertMetricSeries(points.filter { point in
                bodyKeys.contains(point.key) ? point.day >= bodyFrom && point.day <= bodyTo : point.day >= from && point.day <= to
            }, deviceId: deviceId, in: db)
        }
    }

    /// AI-19 repairs wide historical projections from retained metricSeries values, in resumable pages.
    /// No source sample or manual correction is removed. Re-importing Health separately refreshes sleep
    /// provenance; this local repair recovers values blanked by the earlier partial-window upserts.
    public func repairHealthProjectionsV1(batchSize: Int = 90) async throws -> Bool {
        try syncWrite { db in
            let cursorName = "health:wideProjectionRepair.v1"
            let cursor = try String.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?", arguments: [cursorName]) ?? ""
            let days = try String.fetchAll(db, sql: """
                SELECT DISTINCT day FROM metricSeries WHERE deviceId = 'apple-health' AND day > ?
                ORDER BY day LIMIT ?
                """, arguments: [cursor, max(1, batchSize)])
            for day in days {
                let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM metricSeries WHERE deviceId = 'apple-health' AND day = ?", arguments: [day])
                let values = Dictionary(uniqueKeysWithValues: rows.map { ($0["key"] as String, $0["value"] as Double) })
                try db.execute(sql: "INSERT INTO appleDaily(deviceId, day) VALUES ('apple-health', ?) ON CONFLICT DO NOTHING", arguments: [day])
                try db.execute(sql: "INSERT INTO dailyMetric(deviceId, day) VALUES ('apple-health', ?) ON CONFLICT DO NOTHING", arguments: [day])
                for (key, column) in [("steps", "steps"), ("active_kcal", "activeKcal"), ("basal_kcal", "basalKcal"), ("vo2max", "vo2max"), ("avg_hr", "avgHr"), ("max_hr", "maxHr"), ("walking_hr", "walkingHr"), ("weight", "weightKg")] {
                    if let value = values[key], value.isFinite {
                        var projected = value
                        if ["steps", "avgHr", "maxHr", "walkingHr"].contains(column) {
                            guard value > Double(Int.min), value < Double(Int.max) else { continue }
                            projected = column == "steps" ? Double(Int(value)) : value.rounded()
                        }
                        try db.execute(sql: "UPDATE appleDaily SET \(column) = COALESCE(\(column), ?) WHERE deviceId = 'apple-health' AND day = ?", arguments: [projected, day])
                    }
                }
                for (key, column) in [("resting_hr", "restingHr"), ("hrv", "avgHrv"), ("hrv", "avgSdnn"), ("spo2", "spo2Pct"), ("resp_rate", "respRateBpm"), ("asleep_min", "totalSleepMin"), ("deep_min", "deepMin"), ("rem_min", "remMin"), ("core_min", "lightMin")] {
                    if let value = values[key], value.isFinite {
                        if column == "restingHr" {
                            guard value > Double(Int.min), value < Double(Int.max) else { continue }
                        }
                        let projected = column == "restingHr" ? value.rounded() : value
                        try db.execute(sql: "UPDATE dailyMetric SET \(column) = COALESCE(\(column), ?) WHERE deviceId = 'apple-health' AND day = ?", arguments: [projected, day])
                    }
                }
            }
            if let last = days.last {
                // This cursor is a sortable civil-day string stored in SQLite's dynamically typed value.
                try db.execute(sql: "INSERT INTO cursors(name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value", arguments: [cursorName, last])
            }
            return days.count < max(1, batchSize)
        }
    }
}

extension WhoopStore {
    public func healthImportHistoryFloor() async throws -> Int? {
        try syncRead { db in
            let day = try String.fetchOne(db, sql: "SELECT MIN(day) FROM appleDaily WHERE deviceId = 'apple-health'")
            let workout = try Int.fetchOne(db, sql: "SELECT MIN(startTs) FROM workoutSourceMetadata WHERE source = 'apple-health'")
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
            let daily = day.flatMap { formatter.date(from: $0) }.map { Int($0.timeIntervalSince1970) }
            return [daily, workout].compactMap { $0 }.min()
        }
    }
}

extension WhoopStore {
    /// A permission change/deletion arriving during a history page must not be overwritten by that
    /// page's older checkpoint. Generation and rewind are committed in the same SQLite transaction.
    public func requestHealthImportRepair(endTs: Int) async throws {
        try syncWrite { db in
            let generation = try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = 'health:importRepairGeneration.v1'") ?? 0
            for (name, value) in [("health:importRepairGeneration.v1", generation + 1), ("health:importRepair.v1", endTs)] {
                try db.execute(sql: "INSERT INTO cursors(name,value) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value = excluded.value", arguments: [name, value])
            }
        }
    }

    public func checkpointHealthImportRepair(endTs: Int, generation: Int) async throws -> Bool {
        try syncWrite { db in
            let current = try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = 'health:importRepairGeneration.v1'") ?? 0
            guard current == generation else { return false }
            try db.execute(sql: "INSERT INTO cursors(name,value) VALUES ('health:importRepair.v1',?) ON CONFLICT(name) DO UPDATE SET value = excluded.value", arguments: [endTs])
            return true
        }
    }
}
