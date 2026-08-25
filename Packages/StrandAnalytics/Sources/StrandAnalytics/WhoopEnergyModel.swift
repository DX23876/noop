import Foundation

/// Evidence behind a WHOOP energy bucket. Keeping this explicit prevents inferred movement or a
/// basal fill from being presented as directly measured energy.
public enum EnergyEvidence: String, Codable, Equatable, Sendable {
    case observed
    case inferred
    case modeled
}

/// One fixed-width WHOOP energy input window. Callers normally use five-minute buckets; duration is
/// retained so DST boundaries and clipped first/last buckets remain exact.
public struct WhoopEnergyBucket: Equatable, Sendable {
    public let start: Int
    public let durationSeconds: Int
    public let averageHR: Double?
    public let motionIntensity: Double?
    public let steps: Int?
    public let distanceM: Double?
    public let strideM: Double?
    public let isWorkout: Bool
    public let isSleep: Bool
    public let isOffWrist: Bool

    public init(start: Int, durationSeconds: Int = 300, averageHR: Double? = nil,
                motionIntensity: Double? = nil, steps: Int? = nil, distanceM: Double? = nil,
                strideM: Double? = nil, isWorkout: Bool = false, isSleep: Bool = false,
                isOffWrist: Bool = false) {
        self.start = start
        self.durationSeconds = durationSeconds
        self.averageHR = averageHR
        self.motionIntensity = motionIntensity
        self.steps = steps
        self.distanceM = distanceM
        self.strideM = strideM
        self.isWorkout = isWorkout
        self.isSleep = isSleep
        self.isOffWrist = isOffWrist
    }
}

public struct WhoopEnergyBucketResult: Equatable, Sendable {
    public let start: Int
    public let kcal: Double
    public let evidence: EnergyEvidence
}

public struct WhoopDailyEnergyEstimate: Equatable, Sendable {
    public static let modelVersion = "whoop-bucket-v1"

    public let totalKcal: Double
    public let observedSeconds: Int
    public let inferredSeconds: Int
    public let modeledSeconds: Int
    /// Symmetric approximate uncertainty, expressed as a fraction of total energy.
    public let uncertaintyFraction: Double
    public let buckets: [WhoopEnergyBucketResult]

    public var coverageFraction: Double {
        let total = observedSeconds + inferredSeconds + modeledSeconds
        return total > 0 ? Double(observedSeconds) / Double(total) : 0
    }
}

/// Pure WHOOP-first energy model. Apple Health is deliberately absent from these inputs: it is a
/// reference/calibration stream and cannot silently replace or be added to the strap estimate.
public enum WhoopEnergyModel {
    public static let defaultBucketSeconds = 300

    public static func estimate(buckets: [WhoopEnergyBucket], profile: UserProfile,
                                restingHR: Double?, maxHR: Double?) -> WhoopDailyEnergyEstimate? {
        guard let bmr = Calories.bmrKcalPerDay(profile: profile), profile.weightKg > 0 else { return nil }
        let valid = buckets
            .filter { $0.durationSeconds > 0 && $0.durationSeconds <= 900 }
            .sorted { $0.start < $1.start }
        guard !valid.isEmpty else { return nil }

        let basalPerSecond = bmr / 86_400
        var results: [WhoopEnergyBucketResult] = []
        var observed = 0
        var inferred = 0
        var modeled = 0

        for bucket in valid {
            let seconds = bucket.durationSeconds
            let basal = basalPerSecond * Double(seconds)
            let result: WhoopEnergyBucketResult

            if bucket.isOffWrist || bucket.isSleep {
                result = .init(start: bucket.start, kcal: basal, evidence: .modeled)
                modeled += seconds
            } else if let hr = finite(bucket.averageHR), hr >= 30, hr <= 240 {
                let kcal = hrEnergy(hr: hr, seconds: seconds, basal: basal, weightKg: profile.weightKg,
                                    restingHR: restingHR, maxHR: maxHR, workout: bucket.isWorkout)
                result = .init(start: bucket.start, kcal: kcal, evidence: .observed)
                observed += seconds
            } else if hasMovement(bucket) {
                let met = movementMET(bucket)
                let active = max(0, met - 1) * 3.5 * profile.weightKg / 200 * (Double(seconds) / 60)
                result = .init(start: bucket.start, kcal: basal + active, evidence: .inferred)
                inferred += seconds
            } else {
                result = .init(start: bucket.start, kcal: basal, evidence: .modeled)
                modeled += seconds
            }
            results.append(result)
        }

        let total = results.reduce(0) { $0 + $1.kcal }
        let duration = max(1, observed + inferred + modeled)
        // Measurement < movement inference < basal fill. This is intentionally conservative and
        // auditable; calibration later may scale the value but not erase this evidence mix.
        let uncertainty = min(0.50, (0.10 * Double(observed) + 0.22 * Double(inferred)
                                    + 0.35 * Double(modeled)) / Double(duration))
        return .init(totalKcal: total, observedSeconds: observed, inferredSeconds: inferred,
                     modeledSeconds: modeled, uncertaintyFraction: uncertainty, buckets: results)
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func hasMovement(_ bucket: WhoopEnergyBucket) -> Bool {
        (bucket.steps ?? 0) > 0 || (finite(bucket.distanceM) ?? 0) > 0
            || (finite(bucket.motionIntensity) ?? 0) > 0.03
    }

    private static func movementMET(_ bucket: WhoopEnergyBucket) -> Double {
        let minutes = max(1.0 / 60, Double(bucket.durationSeconds) / 60)
        if let distance = finite(bucket.distanceM), distance > 0 {
            let speedKmh = distance / 1_000 / (minutes / 60)
            if speedKmh >= 8 { return min(12, 8 + (speedKmh - 8) * 0.7) }
            if speedKmh >= 5.5 { return 4.3 }
            if speedKmh >= 3 { return 3.0 }
        }
        if let steps = bucket.steps, steps > 0 {
            let cadence = Double(steps) / minutes
            if cadence >= 130 { return 7.0 }
            if cadence >= 100 { return 4.0 }
            if cadence >= 60 { return 2.8 }
        }
        let motion = finite(bucket.motionIntensity) ?? 0
        return motion >= 0.20 ? 3.0 : motion >= 0.08 ? 2.0 : 1.5
    }

    private static func hrEnergy(hr: Double, seconds: Int, basal: Double, weightKg: Double,
                                 restingHR: Double?, maxHR: Double?, workout: Bool) -> Double {
        let resting = min(100, max(35, restingHR ?? 60))
        let maximum = max(resting + 20, maxHR ?? 190)
        let reserve = min(1, max(0, (hr - resting) / (maximum - resting)))
        // HR alone is noisy at low intensity. Only genuine workout/high-HRR buckets receive the
        // steep exercise curve; other HR buckets remain a conservative low-intensity estimate.
        let met: Double
        if workout || reserve >= 0.50 {
            met = min(14, 1 + 11 * reserve * reserve)
        } else {
            met = 1 + 2.5 * reserve
        }
        let active = max(0, met - 1) * 3.5 * weightKg / 200 * (Double(seconds) / 60)
        return basal + active
    }
}

public struct CausalWeightObservation: Equatable, Sendable {
    public enum Source: Int, Equatable, Sendable { case health = 0, manual = 1 }
    public let timestamp: Int
    public let weightKg: Double
    public let source: Source

    public init(timestamp: Int, weightKg: Double, source: Source) {
        self.timestamp = timestamp
        self.weightKg = weightKg
        self.source = source
    }
}

public enum CausalWeightResolver {
    /// Ten-day EWMA using observations available at or before the requested instant. A manual entry
    /// wins over Health on the same local day. Values are carried for at most 90 days; otherwise the
    /// caller's profile fallback is returned at lower confidence by the caller.
    public static func weight(at timestamp: Int, observations: [CausalWeightObservation],
                              calendar: Calendar = .current) -> Double? {
        let eligible = observations.filter {
            $0.timestamp <= timestamp && $0.weightKg.isFinite && (25...350).contains($0.weightKg)
        }
        var byDay: [Date: CausalWeightObservation] = [:]
        for row in eligible.sorted(by: { $0.timestamp < $1.timestamp }) {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(row.timestamp)))
            if let old = byDay[day], old.source.rawValue > row.source.rawValue { continue }
            byDay[day] = row
        }
        let rows = byDay.sorted { $0.key < $1.key }
        guard let last = rows.last,
              timestamp - Int(last.key.timeIntervalSince1970) <= 90 * 86_400 else { return nil }
        let alpha = 2.0 / 11.0
        return rows.reduce(nil as Double?) { smoothed, item in
            guard let smoothed else { return item.value.weightKg }
            return alpha * item.value.weightKg + (1 - alpha) * smoothed
        }
    }
}
