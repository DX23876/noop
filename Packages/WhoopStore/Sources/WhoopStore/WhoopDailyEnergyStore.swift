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
    /// Wall-clock seconds whose basal share is already included in `rawTotalKcal`. Kept separate
    /// from observed HR seconds so evidence provenance and EnergyEngine's basal denominator remain
    /// independently auditable.
    public let representedSeconds: Int
    public let physiologicalSeconds: Int
    /// Stable JSON object keyed by the analytics context raw values. Kept schema-agnostic so the store
    /// package does not depend on StrandAnalytics.
    public let contextJSON: String
    public let uncertaintyFraction: Double
    public let weightKg: Double
    public let weightSource: WeightSource
    /// Moderate-or-harder seconds in bouts of 20 minutes or more, and whether the day held ten
    /// continuous minutes of movement: the evidence the Jurca activity category is measured from.
    public let aerobicSeconds: Int
    public let hadLightActivity: Bool
    /// The aerobic ceiling (METs) confirmed workouts were scaled to, and where it came from
    /// (`manual`, `appleWatch`, `jurca`; raw strings so this package stays free of StrandAnalytics).
    /// Nil when the day had none and workouts were priced from their sport's table.
    public let peakMET: Double?
    public let peakMETSource: String?
    /// The day the ceiling was measured or entered, the value as measured (ml/kg/min) and the weight
    /// it was per kilogram of. Nil for an estimate.
    public let peakMETSourceDay: String?
    public let measuredVO2max: Double?
    public let measuredWeightKg: Double?
    /// The Jurca category (1–5) the estimate used. Nil for a measured ceiling.
    public let activityLevel: Int?

    public init(day: String, rawTotalKcal: Double, modelVersion: String,
                observedSeconds: Int, inferredSeconds: Int, modeledSeconds: Int,
                representedSeconds: Int? = nil, physiologicalSeconds: Int = 0,
                contextJSON: String = "{}",
                uncertaintyFraction: Double, weightKg: Double, weightSource: WeightSource,
                aerobicSeconds: Int = 0, hadLightActivity: Bool = false,
                peakMET: Double? = nil, peakMETSource: String? = nil, peakMETSourceDay: String? = nil,
                measuredVO2max: Double? = nil, measuredWeightKg: Double? = nil,
                activityLevel: Int? = nil) {
        self.day = day
        self.rawTotalKcal = rawTotalKcal
        self.modelVersion = modelVersion
        self.observedSeconds = observedSeconds
        self.inferredSeconds = inferredSeconds
        self.modeledSeconds = modeledSeconds
        self.representedSeconds = representedSeconds
            ?? observedSeconds + inferredSeconds + modeledSeconds + physiologicalSeconds
        self.physiologicalSeconds = physiologicalSeconds
        self.contextJSON = contextJSON
        self.uncertaintyFraction = uncertaintyFraction
        self.weightKg = weightKg
        self.weightSource = weightSource
        self.aerobicSeconds = aerobicSeconds
        self.hadLightActivity = hadLightActivity
        self.peakMET = peakMET
        self.peakMETSource = peakMETSource
        self.peakMETSourceDay = peakMETSourceDay
        self.measuredVO2max = measuredVO2max
        self.measuredWeightKg = measuredWeightKg
        self.activityLevel = activityLevel
    }
}

/// One day's two derived views from the same WHOOP model pass. They are written together so the
/// day total and the personal time-of-day activity shape can never expose different generations.
public struct WhoopEnergyWindowDay: Equatable, Sendable {
    public let daily: WhoopDailyEnergyRow
    public let activeKcalByHour: [Int: Double]
    public let buckets: [WhoopEnergyBucketRow]

    public init(daily: WhoopDailyEnergyRow, activeKcalByHour: [Int: Double],
                buckets: [WhoopEnergyBucketRow] = []) {
        self.daily = daily
        self.activeKcalByHour = activeKcalByHour
        self.buckets = buckets
    }
}

public struct WhoopEnergyBucketRow: Equatable, Sendable {
    public let day: String
    public let bucketStart: Int
    public let durationSeconds: Int
    public let basalKcal: Double
    public let activeKcal: Double
    public let context: String
    public let evidence: String
    public let uncertaintyFraction: Double

    public init(day: String, bucketStart: Int, durationSeconds: Int, basalKcal: Double,
                activeKcal: Double, context: String, evidence: String,
                uncertaintyFraction: Double) {
        self.day = day
        self.bucketStart = bucketStart
        self.durationSeconds = durationSeconds
        self.basalKcal = basalKcal
        self.activeKcal = activeKcal
        self.context = context
        self.evidence = evidence
        self.uncertaintyFraction = uncertaintyFraction
    }
}

extension WhoopStore {
    @discardableResult
    public func upsertWhoopDailyEnergy(_ rows: [WhoopDailyEnergyRow], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var changed = 0
            for row in rows where Self.valid(row) {
                changed += try Self.upsertWhoopDailyEnergy(row, deviceId: deviceId, in: db)
            }
            return changed
        }
    }

    /// Atomically replaces a complete recomputation window. The caller builds every row in memory
    /// first; any SQLite failure rolls back both the daily totals and all hourly activity-shape rows.
    @discardableResult
    public func replaceWhoopEnergyWindow(_ days: [WhoopEnergyWindowDay], deviceId: String)
        async throws -> Int {
        guard !days.isEmpty, !deviceId.isEmpty,
              days.allSatisfy({ Self.valid($0.daily) }) else { return 0 }
        return try syncWrite { db in
            var changed = 0
            // Every day's old buckets go before any new one is written. Day by day, a bucket moving to
            // an earlier day (a 23:55 bucket an older build filed under the next day) collided with its
            // old row, which was only deleted when the loop reached that next day.
            for item in days {
                try db.execute(sql: "DELETE FROM whoopEnergyBucket WHERE deviceId = ? AND day = ?",
                               arguments: [deviceId, item.daily.day])
                changed += db.changesCount
            }
            for item in days {
                for bucket in item.buckets where Self.valid(bucket, day: item.daily.day) {
                    // A bucket start is unique per device. One still filed under a day outside this
                    // window moves to the day that now owns it instead of failing the whole window.
                    try db.execute(sql: """
                        INSERT INTO whoopEnergyBucket
                            (deviceId, day, bucketStart, durationSeconds, basalKcal, activeKcal,
                             context, evidence, uncertaintyFraction)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, bucketStart) DO UPDATE SET
                            day = excluded.day, durationSeconds = excluded.durationSeconds,
                            basalKcal = excluded.basalKcal, activeKcal = excluded.activeKcal,
                            context = excluded.context, evidence = excluded.evidence,
                            uncertaintyFraction = excluded.uncertaintyFraction
                        """, arguments: [deviceId, bucket.day, bucket.bucketStart,
                                          bucket.durationSeconds, bucket.basalKcal,
                                          bucket.activeKcal, bucket.context, bucket.evidence,
                                          bucket.uncertaintyFraction])
                    changed += db.changesCount
                }
                try db.execute(sql: "DELETE FROM whoopEnergyHourly WHERE deviceId = ? AND day = ?",
                               arguments: [deviceId, item.daily.day])
                changed += db.changesCount
                for (hour, kcal) in item.activeKcalByHour.sorted(by: { $0.key < $1.key })
                where (0...23).contains(hour) && kcal.isFinite && kcal >= 0 && kcal <= 5_000 {
                    try db.execute(sql: """
                        INSERT INTO whoopEnergyHourly (deviceId, day, hour, activeKcal)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [deviceId, item.daily.day, hour, kcal])
                    changed += db.changesCount
                }
                changed += try Self.upsertWhoopDailyEnergy(item.daily, deviceId: deviceId, in: db)
            }
            return changed
        }
    }

    public nonisolated func whoopDailyEnergy(deviceId: String, from: String,
                                              to: String) async throws -> [WhoopDailyEnergyRow] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, rawTotalKcal, modelVersion, observedSeconds, inferredSeconds,
                       modeledSeconds, representedSeconds, physiologicalSeconds, contextJSON,
                       uncertaintyFraction, weightKg, weightSource, aerobicSeconds, hadLightActivity,
                       peakMET, peakMETSource, peakMETSourceDay, measuredVO2max, measuredWeightKg,
                       activityLevel
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
                        representedSeconds: row["representedSeconds"],
                        physiologicalSeconds: row["physiologicalSeconds"], contextJSON: row["contextJSON"],
                        uncertaintyFraction: row["uncertaintyFraction"], weightKg: row["weightKg"],
                        weightSource: source, aerobicSeconds: row["aerobicSeconds"],
                        hadLightActivity: row["hadLightActivity"], peakMET: row["peakMET"],
                        peakMETSource: row["peakMETSource"], peakMETSourceDay: row["peakMETSourceDay"],
                        measuredVO2max: row["measuredVO2max"], measuredWeightKg: row["measuredWeightKg"],
                        activityLevel: row["activityLevel"])
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

    public nonisolated func whoopEnergyBuckets(deviceId: String, day: String) async throws
        -> [WhoopEnergyBucketRow] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, bucketStart, durationSeconds, basalKcal, activeKcal, context,
                       evidence, uncertaintyFraction
                FROM whoopEnergyBucket
                WHERE deviceId = ? AND day = ?
                ORDER BY bucketStart ASC
                """, arguments: [deviceId, day]).map {
                    WhoopEnergyBucketRow(day: $0["day"], bucketStart: $0["bucketStart"],
                                         durationSeconds: $0["durationSeconds"],
                                         basalKcal: $0["basalKcal"], activeKcal: $0["activeKcal"],
                                         context: $0["context"], evidence: $0["evidence"],
                                         uncertaintyFraction: $0["uncertaintyFraction"])
                }
        }
    }

    // Split into separate guards: one long `&&` chain exceeded the type checker's time limit on the
    // CI runner's older Swift, although newer compilers accept it.
    private static func valid(_ row: WhoopDailyEnergyRow) -> Bool {
        guard row.day.count == 10, row.rawTotalKcal.isFinite, row.rawTotalKcal >= 0,
              !row.modelVersion.isEmpty else { return false }
        guard row.observedSeconds >= 0, row.inferredSeconds >= 0, row.modeledSeconds >= 0,
              row.representedSeconds >= 0, row.physiologicalSeconds >= 0 else { return false }
        let evidenceSeconds: Int = row.observedSeconds + row.inferredSeconds
            + row.modeledSeconds + row.physiologicalSeconds
        guard row.representedSeconds == evidenceSeconds, row.representedSeconds <= 100_000 else {
            return false
        }
        guard !row.contextJSON.isEmpty, row.uncertaintyFraction.isFinite,
              (0...1).contains(row.uncertaintyFraction) else { return false }
        guard row.weightKg.isFinite, (25...350).contains(row.weightKg) else { return false }
        guard row.aerobicSeconds >= 0, row.aerobicSeconds <= 86_400 else { return false }
        if let peak = row.peakMET, !(peak.isFinite && peak > 0) { return false }
        return true
    }

    private static func valid(_ row: WhoopEnergyBucketRow, day: String) -> Bool {
        row.day == day && row.day.count == 10 && row.bucketStart > 0
            && (1...900).contains(row.durationSeconds)
            && row.basalKcal.isFinite && row.basalKcal >= 0 && row.basalKcal <= 1_000
            && row.activeKcal.isFinite && row.activeKcal >= 0 && row.activeKcal <= 2_000
            && !row.context.isEmpty && !row.evidence.isEmpty
            && row.uncertaintyFraction.isFinite && (0...1).contains(row.uncertaintyFraction)
    }

    private static func upsertWhoopDailyEnergy(_ row: WhoopDailyEnergyRow, deviceId: String,
                                               in db: Database) throws -> Int {
        // Two literals joined rather than one: a 21-element mixed-type literal risks the CI runner's
        // older type checker, which already timed out on a long expression in this file.
        let base: StatementArguments = [deviceId, row.day, row.rawTotalKcal, row.modelVersion,
                                        row.observedSeconds, row.inferredSeconds, row.modeledSeconds,
                                        row.representedSeconds, row.physiologicalSeconds, row.contextJSON,
                                        row.uncertaintyFraction, row.weightKg, row.weightSource.rawValue]
        let fitness: StatementArguments = [row.aerobicSeconds, row.hadLightActivity, row.peakMET,
                                           row.peakMETSource, row.peakMETSourceDay, row.measuredVO2max,
                                           row.measuredWeightKg, row.activityLevel]
        let arguments = base + fitness
        try db.execute(sql: """
            INSERT INTO whoopDailyEnergy
                (deviceId, day, rawTotalKcal, modelVersion, observedSeconds,
                 inferredSeconds, modeledSeconds, representedSeconds, physiologicalSeconds, contextJSON,
                 uncertaintyFraction, weightKg, weightSource, aerobicSeconds, hadLightActivity,
                 peakMET, peakMETSource, peakMETSourceDay, measuredVO2max, measuredWeightKg, activityLevel)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(deviceId, day) DO UPDATE SET
                rawTotalKcal = excluded.rawTotalKcal,
                modelVersion = excluded.modelVersion,
                observedSeconds = excluded.observedSeconds,
                inferredSeconds = excluded.inferredSeconds,
                modeledSeconds = excluded.modeledSeconds,
                representedSeconds = excluded.representedSeconds,
                physiologicalSeconds = excluded.physiologicalSeconds,
                contextJSON = excluded.contextJSON,
                uncertaintyFraction = excluded.uncertaintyFraction,
                weightKg = excluded.weightKg,
                weightSource = excluded.weightSource,
                aerobicSeconds = excluded.aerobicSeconds,
                hadLightActivity = excluded.hadLightActivity,
                peakMET = excluded.peakMET,
                peakMETSource = excluded.peakMETSource,
                peakMETSourceDay = excluded.peakMETSourceDay,
                measuredVO2max = excluded.measuredVO2max,
                measuredWeightKg = excluded.measuredWeightKg,
                activityLevel = excluded.activityLevel
            WHERE rawTotalKcal IS NOT excluded.rawTotalKcal
               OR modelVersion IS NOT excluded.modelVersion
               OR observedSeconds IS NOT excluded.observedSeconds
               OR inferredSeconds IS NOT excluded.inferredSeconds
               OR modeledSeconds IS NOT excluded.modeledSeconds
               OR representedSeconds IS NOT excluded.representedSeconds
               OR physiologicalSeconds IS NOT excluded.physiologicalSeconds
               OR contextJSON IS NOT excluded.contextJSON
               OR uncertaintyFraction IS NOT excluded.uncertaintyFraction
               OR weightKg IS NOT excluded.weightKg
               OR weightSource IS NOT excluded.weightSource
               OR aerobicSeconds IS NOT excluded.aerobicSeconds
               OR hadLightActivity IS NOT excluded.hadLightActivity
               OR peakMET IS NOT excluded.peakMET
               OR peakMETSource IS NOT excluded.peakMETSource
               OR peakMETSourceDay IS NOT excluded.peakMETSourceDay
               OR measuredVO2max IS NOT excluded.measuredVO2max
               OR measuredWeightKg IS NOT excluded.measuredWeightKg
               OR activityLevel IS NOT excluded.activityLevel
            """, arguments: arguments)
        return db.changesCount
    }
}
