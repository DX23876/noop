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

    private static func valid(_ row: WhoopDailyEnergyRow) -> Bool {
        row.day.count == 10 && row.rawTotalKcal.isFinite && row.rawTotalKcal >= 0
            && !row.modelVersion.isEmpty && row.observedSeconds >= 0 && row.inferredSeconds >= 0
            && row.modeledSeconds >= 0 && row.uncertaintyFraction.isFinite
            && (0...1).contains(row.uncertaintyFraction) && row.weightKg.isFinite
            && (25...350).contains(row.weightKg)
    }
}
