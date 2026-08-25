import Foundation
import GRDB

public struct EnergyCalibrationModelRow: Equatable, Sendable {
    public let deviceId: String
    public let referenceDeviceId: String
    public let enabled: Bool
    public let factor: Double
    public let sampleDays: Int
    public let sampleBuckets: Int
    public let coefficientOfVariation: Double
    public let fittedAt: Int
    public let modelVersion: String

    public init(deviceId: String, referenceDeviceId: String, enabled: Bool, factor: Double,
                sampleDays: Int, sampleBuckets: Int, coefficientOfVariation: Double,
                fittedAt: Int, modelVersion: String) {
        self.deviceId = deviceId
        self.referenceDeviceId = referenceDeviceId
        self.enabled = enabled
        self.factor = factor
        self.sampleDays = sampleDays
        self.sampleBuckets = sampleBuckets
        self.coefficientOfVariation = coefficientOfVariation
        self.fittedAt = fittedAt
        self.modelVersion = modelVersion
    }
}

extension WhoopStore {
    @discardableResult
    public func saveEnergyCalibrationModel(_ row: EnergyCalibrationModelRow) async throws -> Bool {
        guard Self.validEnergyCalibration(row) else { return false }
        return try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO energyCalibrationModel
                    (deviceId, referenceDeviceId, enabled, factor, sampleDays, sampleBuckets,
                     coefficientOfVariation, fittedAt, modelVersion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId) DO UPDATE SET
                    referenceDeviceId = excluded.referenceDeviceId,
                    enabled = excluded.enabled,
                    factor = excluded.factor,
                    sampleDays = excluded.sampleDays,
                    sampleBuckets = excluded.sampleBuckets,
                    coefficientOfVariation = excluded.coefficientOfVariation,
                    fittedAt = excluded.fittedAt,
                    modelVersion = excluded.modelVersion
                """, arguments: [row.deviceId, row.referenceDeviceId, row.enabled, row.factor,
                                  row.sampleDays, row.sampleBuckets, row.coefficientOfVariation,
                                  row.fittedAt, row.modelVersion])
            return db.changesCount > 0
        }
    }

    public nonisolated func energyCalibrationModel(deviceId: String) async throws
        -> EnergyCalibrationModelRow? {
        try await asyncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM energyCalibrationModel WHERE deviceId = ? LIMIT 1",
                             arguments: [deviceId]).map(Self.decodeEnergyCalibration)
        }
    }

    /// Enable/pause only an existing valid fit. A missing row remains disabled rather than creating
    /// a factor of 1 that would misleadingly look calibrated.
    @discardableResult
    public func setEnergyCalibrationEnabled(deviceId: String, enabled: Bool) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "UPDATE energyCalibrationModel SET enabled = ? WHERE deviceId = ?",
                           arguments: [enabled, deviceId])
            return db.changesCount > 0
        }
    }

    /// User-facing reset: removes the fit. Reference buckets remain so a later explicit opt-in can
    /// learn again without asking HealthKit to re-import historical samples.
    @discardableResult
    public func resetEnergyCalibration(deviceId: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM energyCalibrationModel WHERE deviceId = ?", arguments: [deviceId])
            return db.changesCount > 0
        }
    }

    private static func decodeEnergyCalibration(_ row: Row) -> EnergyCalibrationModelRow {
        .init(deviceId: row["deviceId"], referenceDeviceId: row["referenceDeviceId"],
              enabled: row["enabled"], factor: row["factor"], sampleDays: row["sampleDays"],
              sampleBuckets: row["sampleBuckets"],
              coefficientOfVariation: row["coefficientOfVariation"], fittedAt: row["fittedAt"],
              modelVersion: row["modelVersion"])
    }

    private static func validEnergyCalibration(_ row: EnergyCalibrationModelRow) -> Bool {
        !row.deviceId.isEmpty && !row.referenceDeviceId.isEmpty && !row.modelVersion.isEmpty
            && row.factor.isFinite && (0.8...1.2).contains(row.factor) && row.sampleDays >= 7
            && row.sampleBuckets >= 84 && row.coefficientOfVariation.isFinite
            && (0...0.2).contains(row.coefficientOfVariation) && row.fittedAt > 0
    }
}
