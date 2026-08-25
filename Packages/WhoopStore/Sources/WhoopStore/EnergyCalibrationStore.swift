import Foundation
import GRDB

/// Coarse provenance for Apple Health reference data. Only `appleWatch` is eligible to teach a
/// WHOOP calibration; the remaining cases are retained for diagnostics and source arbitration.
public enum HealthEnergySourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case appleWatch
    case iPhone
    case noop
    case thirdParty
    case unknown

    public var calibrationEligible: Bool { self == .appleWatch }
}

/// A bounded five-minute reference bucket. It intentionally contains no raw HealthKit identifiers
/// or samples and is keyed by a normalized source id plus bucket start.
public struct HealthEnergyBucketRow: Codable, Equatable, Sendable {
    public static let durationSeconds = 300

    public var deviceId: String
    public var sourceId: String
    public var sourceKind: HealthEnergySourceKind
    public var bucketStart: Int
    public var activeKcal: Double?
    public var basalKcal: Double?
    public var averageHr: Double?
    public var steps: Int?
    public var distanceM: Double?
    public var strideM: Double?
    public var workout: Bool
    public var coverageSeconds: Int
    public var sampleCount: Int
    public var quality: Double?

    public init(deviceId: String, sourceId: String, sourceKind: HealthEnergySourceKind,
                bucketStart: Int, activeKcal: Double? = nil, basalKcal: Double? = nil,
                averageHr: Double? = nil, steps: Int? = nil, distanceM: Double? = nil,
                strideM: Double? = nil, workout: Bool = false, coverageSeconds: Int = 0,
                sampleCount: Int = 0, quality: Double? = nil) {
        self.deviceId = deviceId
        self.sourceId = sourceId
        self.sourceKind = sourceKind
        self.bucketStart = (bucketStart / Self.durationSeconds) * Self.durationSeconds
        self.activeKcal = activeKcal
        self.basalKcal = basalKcal
        self.averageHr = averageHr
        self.steps = steps
        self.distanceM = distanceM
        self.strideM = strideM
        self.workout = workout
        self.coverageSeconds = min(Self.durationSeconds, max(0, coverageSeconds))
        self.sampleCount = max(0, sampleCount)
        self.quality = quality.map { min(1, max(0, $0)) }
    }

    static func decode(_ row: Row) -> Self {
        Self(deviceId: row["deviceId"], sourceId: row["sourceId"],
             sourceKind: HealthEnergySourceKind(rawValue: row["sourceKind"]) ?? .unknown,
             bucketStart: row["bucketStart"], activeKcal: row["activeKcal"],
             basalKcal: row["basalKcal"], averageHr: row["averageHr"], steps: row["steps"],
             distanceM: row["distanceM"], strideM: row["strideM"], workout: row["workout"],
             coverageSeconds: row["coverageSeconds"], sampleCount: row["sampleCount"],
             quality: row["quality"])
    }
}

extension WhoopStore {
    /// Replaces matching buckets idempotently. Values are sanitized before persistence so malformed
    /// Health records cannot poison a later calibration fit.
    @discardableResult
    public func upsertHealthEnergyBuckets(_ rows: [HealthEnergyBucketRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var count = 0
            for raw in rows {
                let r = HealthEnergyBucketRow(
                    deviceId: raw.deviceId, sourceId: raw.sourceId, sourceKind: raw.sourceKind,
                    bucketStart: raw.bucketStart, activeKcal: Self.valid(raw.activeKcal, max: 2_000),
                    basalKcal: Self.valid(raw.basalKcal, max: 1_000),
                    averageHr: Self.valid(raw.averageHr, min: 20, max: 260),
                    steps: raw.steps.flatMap { (0...5_000).contains($0) ? $0 : nil },
                    distanceM: Self.valid(raw.distanceM, max: 10_000),
                    strideM: Self.valid(raw.strideM, min: 0.2, max: 3.0), workout: raw.workout,
                    coverageSeconds: raw.coverageSeconds, sampleCount: raw.sampleCount,
                    quality: raw.quality)
                try db.execute(sql: """
                    INSERT INTO healthEnergyBucket
                      (deviceId, sourceId, sourceKind, bucketStart, activeKcal, basalKcal, averageHr,
                       steps, distanceM, strideM, workout, coverageSeconds, sampleCount, quality)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, sourceId, bucketStart) DO UPDATE SET
                      sourceKind=excluded.sourceKind, activeKcal=excluded.activeKcal,
                      basalKcal=excluded.basalKcal, averageHr=excluded.averageHr,
                      steps=excluded.steps, distanceM=excluded.distanceM, strideM=excluded.strideM,
                      workout=excluded.workout, coverageSeconds=excluded.coverageSeconds,
                      sampleCount=excluded.sampleCount, quality=excluded.quality
                    """, arguments: [r.deviceId, r.sourceId, r.sourceKind.rawValue, r.bucketStart,
                                      r.activeKcal, r.basalKcal, r.averageHr, r.steps, r.distanceM,
                                      r.strideM, r.workout, r.coverageSeconds, r.sampleCount, r.quality])
                count += db.changesCount
            }
            return count
        }
    }

    public func healthEnergyBuckets(deviceId: String, from: Int, to: Int,
                                    eligibleOnly: Bool = false) async throws -> [HealthEnergyBucketRow] {
        try syncRead { db in
            var sql = """
                SELECT * FROM healthEnergyBucket
                WHERE deviceId = ? AND bucketStart >= ? AND bucketStart < ?
                """
            if eligibleOnly { sql += " AND sourceKind = 'appleWatch'" }
            sql += " ORDER BY bucketStart ASC, sourceId ASC"
            return try Row.fetchAll(db, sql: sql, arguments: [deviceId, from, to])
                .map(HealthEnergyBucketRow.decode)
        }
    }

    /// Removes and reimports a bounded Health window without touching WHOOP-derived rows.
    public func deleteHealthEnergyBuckets(deviceId: String, from: Int, to: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM healthEnergyBucket
                WHERE deviceId = ? AND bucketStart >= ? AND bucketStart < ?
                """, arguments: [deviceId, from, to])
        }
    }

    private static func valid(_ value: Double?, min: Double = 0, max: Double) -> Double? {
        guard let value, value.isFinite, value >= min, value <= max else { return nil }
        return value
    }
}
