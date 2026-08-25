import Foundation
import GRDB

public struct WhoopDailyEnergyRow: Equatable, Sendable {
    public enum WeightSource: String, Sendable { case history, profile }

    public let day: String
    public let rawTotalKcal: Double
    public let modelVersion: String
    public let observedSeconds: Int
    public let inferredSeconds: Int
    public let modeledSeconds: Int
    public let uncertaintyFraction: Double
    public let weightKg: Double
    public let weightSource: WeightSource

    public init(day: String, rawTotalKcal: Double, modelVersion: String,
                observedSeconds: Int, inferredSeconds: Int, modeledSeconds: Int,
                uncertaintyFraction: Double, weightKg: Double, weightSource: WeightSource) {
        self.day = day
        self.rawTotalKcal = rawTotalKcal
        self.modelVersion = modelVersion
        self.observedSeconds = observedSeconds
        self.inferredSeconds = inferredSeconds
        self.modeledSeconds = modeledSeconds
        self.uncertaintyFraction = uncertaintyFraction
        self.weightKg = weightKg
        self.weightSource = weightSource
    }
}

extension WhoopStore {
    @discardableResult
    public func upsertWhoopDailyEnergy(_ rows: [WhoopDailyEnergyRow], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var changed = 0
            for row in rows where Self.valid(row) {
                try db.execute(sql: """
                    INSERT INTO whoopDailyEnergy
                        (deviceId, day, rawTotalKcal, modelVersion, observedSeconds,
                         inferredSeconds, modeledSeconds, uncertaintyFraction, weightKg, weightSource)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET
                        rawTotalKcal = excluded.rawTotalKcal,
                        modelVersion = excluded.modelVersion,
                        observedSeconds = excluded.observedSeconds,
                        inferredSeconds = excluded.inferredSeconds,
                        modeledSeconds = excluded.modeledSeconds,
                        uncertaintyFraction = excluded.uncertaintyFraction,
                        weightKg = excluded.weightKg,
                        weightSource = excluded.weightSource
                    WHERE rawTotalKcal IS NOT excluded.rawTotalKcal
                       OR modelVersion IS NOT excluded.modelVersion
                       OR observedSeconds IS NOT excluded.observedSeconds
                       OR inferredSeconds IS NOT excluded.inferredSeconds
                       OR modeledSeconds IS NOT excluded.modeledSeconds
                       OR uncertaintyFraction IS NOT excluded.uncertaintyFraction
                       OR weightKg IS NOT excluded.weightKg
                       OR weightSource IS NOT excluded.weightSource
                    """, arguments: [deviceId, row.day, row.rawTotalKcal, row.modelVersion,
                                     row.observedSeconds, row.inferredSeconds, row.modeledSeconds,
                                     row.uncertaintyFraction, row.weightKg, row.weightSource.rawValue])
                changed += db.changesCount
            }
            return changed
        }
    }

    public nonisolated func whoopDailyEnergy(deviceId: String, from: String,
                                              to: String) async throws -> [WhoopDailyEnergyRow] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, rawTotalKcal, modelVersion, observedSeconds, inferredSeconds,
                       modeledSeconds, uncertaintyFraction, weightKg, weightSource
                FROM whoopDailyEnergy
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to]).compactMap { row in
                    guard let source = WhoopDailyEnergyRow.WeightSource(rawValue: row["weightSource"]) else {
                        return nil
                    }
                    return WhoopDailyEnergyRow(
                        day: row["day"], rawTotalKcal: row["rawTotalKcal"],
                        modelVersion: row["modelVersion"], observedSeconds: row["observedSeconds"],
                        inferredSeconds: row["inferredSeconds"], modeledSeconds: row["modeledSeconds"],
                        uncertaintyFraction: row["uncertaintyFraction"], weightKg: row["weightKg"],
                        weightSource: source)
                }
        }
    }

    @discardableResult
    public func deleteWhoopDailyEnergy(deviceId: String, from: String, to: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM whoopDailyEnergy WHERE deviceId = ? AND day >= ? AND day <= ?",
                           arguments: [deviceId, from, to])
            return db.changesCount
        }
    }

    /// Replace one day's hourly ACTIVE-energy profile (`v48`). A whole-day replace rather than a
    /// per-hour upsert: a recomputed day must not leave an old hour behind, which is exactly what a
    /// merge would do when the new pass produces fewer hours than the previous one.
    @discardableResult
    public func replaceWhoopEnergyHours(day: String, deviceId: String,
                                        activeKcalByHour: [Int: Double]) async throws -> Int {
        guard day.count == 10, !deviceId.isEmpty else { return 0 }
        return try syncWrite { db in
            try db.execute(sql: "DELETE FROM whoopEnergyHourly WHERE deviceId = ? AND day = ?",
                           arguments: [deviceId, day])
            var written = 0
            for (hour, kcal) in activeKcalByHour.sorted(by: { $0.key < $1.key })
            where (0...23).contains(hour) && kcal.isFinite && kcal >= 0 && kcal <= 5_000 {
                try db.execute(sql: """
                    INSERT INTO whoopEnergyHourly (deviceId, day, hour, activeKcal)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [deviceId, day, hour, kcal])
                written += 1
            }
            return written
        }
    }

    /// One row per (day, hour) that carried active energy, oldest first. Hours with no row are absent
    /// rather than zero; the caller fills a 24-slot vector so a quiet hour reads as a real zero.
    public nonisolated func whoopEnergyHours(deviceId: String, from: String,
                                             to: String) async throws -> [(day: String, hour: Int, activeKcal: Double)] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, hour, activeKcal FROM whoopEnergyHourly
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC, hour ASC
                """, arguments: [deviceId, from, to])
                .map { (day: $0["day"], hour: $0["hour"], activeKcal: $0["activeKcal"]) }
        }
    }

    private static func valid(_ row: WhoopDailyEnergyRow) -> Bool {
        row.day.count == 10 && row.rawTotalKcal.isFinite && row.rawTotalKcal >= 0
            && !row.modelVersion.isEmpty && row.observedSeconds >= 0 && row.inferredSeconds >= 0
            && row.modeledSeconds >= 0 && row.uncertaintyFraction.isFinite
            && (0...1).contains(row.uncertaintyFraction) && row.weightKg.isFinite
            && (25...350).contains(row.weightKg)
    }
}
