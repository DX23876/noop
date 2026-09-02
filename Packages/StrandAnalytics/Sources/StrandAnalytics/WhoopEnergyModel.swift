import Foundation

/// Evidence behind a WHOOP energy bucket. Keeping this explicit prevents inferred movement or a
/// basal fill from being presented as directly measured energy.
public enum EnergyEvidence: String, Codable, Equatable, Sendable {
    case observed
    case inferred
    /// Heart rate was observed, but the energy above basal is a deliberately bounded physiological
    /// estimate rather than evidence of activity.
    case physiological
    case modeled
}

/// The context selected before any calorie equation runs. Heart rate is an intensity input inside a
/// context; it is never, by itself, proof that the wearer was active.
public enum EnergyContext: String, Codable, CaseIterable, Equatable, Sendable {
    case offWrist
    case sleep
    case confirmedWorkout
    case locomotion
    case sedentary
    case unresolvedElevatedHR
    case unknown
}

public enum EnergyWorkoutKind: String, Codable, Equatable, Sendable {
    case endurance
    case resistance
    case other
}

/// One fixed-width WHOOP energy input window. Callers normally use five-minute buckets; duration is
/// retained so DST boundaries and clipped first/last buckets remain exact.
public struct WhoopEnergyBucket: Equatable, Sendable {
    public let start: Int
    public let durationSeconds: Int
    /// Seconds inside the wall-clock bucket backed by HR. Movement can cover the full bucket even when
    /// optical samples are sparse; keeping these durations separate prevents cadence inflation.
    public let hrCoverageSeconds: Int
    public let averageHR: Double?
    public let motionIntensity: Double?
    public let steps: Int?
    public let distanceM: Double?
    public let strideM: Double?
    /// The strap's OWN `activity_class@63` code — 0 still / 1 walk / 2 run. A direct classification
    /// rather than something inferred from cadence, so it sets a floor the weaker signals cannot pull
    /// below. WHOOP 5/MG only: a 4.0 record carries no such field and leaves this nil.
    public let activityClass: Int?
    /// Seconds in this bucket for which movement was independently observed. A few steps near a
    /// five-minute boundary must not turn the entire bucket into five minutes of walking.
    public let movementSeconds: Int
    /// True when a dense movement stream covered this window. This distinguishes a real still reading
    /// (`activityClass == 0`, no counter delta) from a WHOOP 4 / data-gap bucket with no motion evidence.
    public let hasMovementCoverage: Bool
    public let isWorkout: Bool
    public let workoutKind: EnergyWorkoutKind
    public let isSleep: Bool
    public let isOffWrist: Bool

    public init(start: Int, durationSeconds: Int = 300, hrCoverageSeconds: Int? = nil,
                averageHR: Double? = nil,
                motionIntensity: Double? = nil, steps: Int? = nil, distanceM: Double? = nil,
                strideM: Double? = nil, activityClass: Int? = nil, isWorkout: Bool = false,
                workoutKind: EnergyWorkoutKind = .other, isSleep: Bool = false,
                isOffWrist: Bool = false, hasMovementCoverage: Bool = false,
                movementSeconds: Int? = nil) {
        self.start = start
        self.durationSeconds = durationSeconds
        self.hrCoverageSeconds = min(durationSeconds, max(0, hrCoverageSeconds
            ?? (averageHR == nil ? 0 : durationSeconds)))
        self.averageHR = averageHR
        self.motionIntensity = motionIntensity
        self.steps = steps
        self.distanceM = distanceM
        self.strideM = strideM
        self.activityClass = activityClass
        self.movementSeconds = min(durationSeconds, max(0, movementSeconds ?? durationSeconds))
        self.hasMovementCoverage = hasMovementCoverage
        self.isWorkout = isWorkout
        self.workoutKind = workoutKind
        self.isSleep = isSleep
        self.isOffWrist = isOffWrist
    }
}

public struct WhoopEnergyBucketResult: Equatable, Sendable {
    public let start: Int
    public let kcal: Double
    public let activeKcal: Double
    public let evidence: EnergyEvidence
    public let context: EnergyContext
    public let uncertaintyFraction: Double
}

public struct WhoopDailyEnergyEstimate: Equatable, Sendable {
    /// v5 (2026-08-29): heart rate without independently confirmed movement or a workout contributes
    /// no active energy. Locomotion is charged only for its observed movement seconds rather than the
    /// entire five-minute bucket. Bumped so every v4 physiological allowance is recomputed away.
    public static let modelVersion = "whoop-bucket-v5"

    public let totalKcal: Double
    public let observedSeconds: Int
    public let inferredSeconds: Int
    public let modeledSeconds: Int
    public let physiologicalSeconds: Int
    public let contextSeconds: [EnergyContext: Int]
    /// Symmetric approximate uncertainty, expressed as a fraction of total energy.
    public let uncertaintyFraction: Double
    public let buckets: [WhoopEnergyBucketResult]

    /// Wall-clock seconds whose basal share is already present in `totalKcal`. This is the denominator
    /// `EnergyEngine` must use when topping up the unmodelled remainder of a day; using HR coverage here
    /// would add basal twice for movement-backed or otherwise modelled seconds without optical samples.
    public var representedSeconds: Int {
        observedSeconds + inferredSeconds + physiologicalSeconds + modeledSeconds
    }

    public var coverageFraction: Double {
        let total = representedSeconds
        return total > 0 ? Double(observedSeconds + physiologicalSeconds) / Double(total) : 0
    }
}

/// Pure WHOOP-first energy model. Apple Health is deliberately absent from these inputs: it is a
/// reference/calibration stream and cannot silently replace or be added to the strap estimate.
public enum WhoopEnergyModel {
    public static let defaultBucketSeconds = 300

    public static func estimate(buckets: [WhoopEnergyBucket], profile: UserProfile,
                                restingHR: Double?, maxHR: Double?, flexHR: Double? = nil)
        -> WhoopDailyEnergyEstimate? {
        guard let bmr = Calories.bmrKcalPerDay(profile: profile), profile.weightKg > 0 else { return nil }
        let valid = buckets
            .filter { $0.durationSeconds > 0 && $0.durationSeconds <= 900 }
            .sorted { $0.start < $1.start }
        guard !valid.isEmpty else { return nil }

        let basalPerSecond = bmr / 86_400
        var results: [WhoopEnergyBucketResult] = []
        var observed = 0
        var inferred = 0
        var physiological = 0
        var modeled = 0
        var contextSeconds: [EnergyContext: Int] = [:]

        for bucket in valid {
            let seconds = bucket.durationSeconds
            let hrSeconds = min(seconds, max(0, bucket.hrCoverageSeconds))
            let basal = basalPerSecond * Double(seconds)
            let result: WhoopEnergyBucketResult
            let hr = finite(bucket.averageHR).flatMap { (30...240).contains($0) ? $0 : nil }
            let resting = min(100, max(35, restingHR ?? 60))
            let maximum = max(resting + 20, maxHR ?? 190)
            let flex = min(maximum, max(resting, flexHR ?? resting + 20))

            if bucket.isOffWrist {
                result = bucketResult(bucket, basal: basal, active: 0, evidence: .modeled,
                                      context: .offWrist, uncertainty: 0.30)
                modeled += seconds
            } else if bucket.isSleep {
                result = bucketResult(bucket, basal: basal, active: 0, evidence: .modeled,
                                      context: .sleep, uncertainty: 0.20)
                modeled += seconds
            } else if bucket.isWorkout, let hr {
                let met = workoutMET(hr: hr, resting: resting, maximum: maximum,
                                     kind: bucket.workoutKind)
                let active = activeKcal(met: met, seconds: seconds, weightKg: profile.weightKg)
                result = bucketResult(bucket, basal: basal, active: active, evidence: .observed,
                                      context: .confirmedWorkout, uncertainty: 0.18)
                observed += hrSeconds
                inferred += seconds - hrSeconds
            } else if hasMovement(bucket) {
                let movementSeconds = min(seconds, max(0, bucket.movementSeconds))
                let movement = movementMET(bucket)
                // Locomotion is anchored to speed/cadence. HR can make a bounded secondary correction,
                // but cannot turn an ordinary walk into a maximal-effort bucket.
                let met: Double
                if let hr {
                    let exercise = workoutMET(hr: hr, resting: resting, maximum: maximum,
                                              kind: .endurance)
                    met = min(14.5, movement + min(1.5, max(0, exercise - movement) * 0.25))
                } else {
                    met = movement
                }
                let active = activeKcal(met: met, seconds: movementSeconds,
                                        weightKg: profile.weightKg)
                result = bucketResult(bucket, basal: basal, active: active,
                                      evidence: hr == nil ? .inferred : .observed,
                                      context: .locomotion, uncertainty: hr == nil ? 0.28 : 0.20)
                if hr == nil {
                    inferred += seconds
                } else {
                    observed += hrSeconds
                    inferred += seconds - hrSeconds
                }
            } else if let hr {
                let context: EnergyContext
                if bucket.hasMovementCoverage {
                    context = hr > flex ? .unresolvedElevatedHR : .sedentary
                } else {
                    context = .unknown
                }
                result = bucketResult(bucket, basal: basal, active: 0,
                                      evidence: .physiological, context: context,
                                      uncertainty: context == .unknown ? 0.40 : 0.35)
                physiological += hrSeconds
                modeled += seconds - hrSeconds
            } else if bucket.hasMovementCoverage {
                result = bucketResult(bucket, basal: basal, active: 0, evidence: .modeled,
                                      context: .sedentary, uncertainty: 0.30)
                modeled += seconds
            } else {
                result = bucketResult(bucket, basal: basal, active: 0, evidence: .modeled,
                                      context: .unknown, uncertainty: 0.45)
                modeled += seconds
            }
            contextSeconds[result.context, default: 0] += seconds
            results.append(result)
        }

        let total = results.reduce(0) { $0 + $1.kcal }
        let duration = max(1, observed + inferred + physiological + modeled)
        let uncertaintyNumerator = zip(results, valid).reduce(0.0) { partial, pair in
            partial + pair.0.uncertaintyFraction * Double(pair.1.durationSeconds)
        }
        let uncertainty = min(0.60, uncertaintyNumerator / Double(duration))
        return .init(totalKcal: total, observedSeconds: observed, inferredSeconds: inferred,
                     modeledSeconds: modeled, physiologicalSeconds: physiological,
                     contextSeconds: contextSeconds, uncertaintyFraction: uncertainty, buckets: results)
    }

    private static func bucketResult(_ bucket: WhoopEnergyBucket, basal: Double, active: Double,
                                     evidence: EnergyEvidence, context: EnergyContext,
                                     uncertainty: Double) -> WhoopEnergyBucketResult {
        .init(start: bucket.start, kcal: basal + active, activeKcal: active, evidence: evidence,
              context: context, uncertaintyFraction: uncertainty)
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// Whether this bucket carries any INDEPENDENT movement signal. Load-bearing as a guard rather
    /// than a hint: `movementMET` floors at 1.5 even with nothing to go on, so calling it
    /// unconditionally would credit every still, awake, measured-HR bucket half a MET of invented
    /// activity — over a mostly-sedentary day that is hundreds of phantom kcal.
    private static func hasMovement(_ bucket: WhoopEnergyBucket) -> Bool {
        (bucket.steps ?? 0) > 0 || (finite(bucket.distanceM) ?? 0) > 0
            || (finite(bucket.motionIntensity) ?? 0) > 0.03
            || (bucket.activityClass ?? 0) > 0
    }

    /// Walking/running speed -> MET, piecewise-linear between published reference points
    /// (Ainsworth et al., "2011 Compendium of Physical Activities" — the standard reference table
    /// for activity METs). Replaces two independently-tuned tables (one for GPS distance/speed, one
    /// for step cadence) that disagreed with each other, and with the Compendium, by up to 2.7 MET
    /// at the same real speed — see `fork/decisions.md`, 2026-08-26. Strictly increasing in both
    /// columns; `metForSpeed` relies on that for its interpolation.
    private static let speedMETTable: [(kmh: Double, met: Double)] = [
        (0.0, 1.5),
        (3.2, 2.8), (4.0, 3.0), (4.8, 3.5), (5.6, 4.3), (6.4, 5.0), (7.2, 7.0),
        // Running overtakes "very brisk walking" here — a real physiological crossover (race-walking
        // at that pace costs more than an easy jog), not a smoothing artifact.
        (8.0, 8.3), (9.7, 9.8), (11.3, 11.0), (12.9, 11.8), (14.5, 12.8), (16.1, 14.5),
    ]

    private static func metForSpeed(_ kmh: Double) -> Double {
        guard let first = speedMETTable.first, let last = speedMETTable.last else { return 1.5 }
        if kmh <= first.kmh { return first.met }
        if kmh >= last.kmh { return last.met }
        for (a, b) in zip(speedMETTable, speedMETTable.dropFirst()) where kmh <= b.kmh {
            let t = (kmh - a.kmh) / (b.kmh - a.kmh)
            return a.met + (b.met - a.met) * t
        }
        return last.met
    }

    private static func movementMET(_ bucket: WhoopEnergyBucket) -> Double {
        let minutes = max(1.0 / 60, Double(bucket.movementSeconds) / 60)
        var met: Double
        if let distance = finite(bucket.distanceM), distance > 0 {
            let speedKmh = distance / 1_000 / (minutes / 60)
            met = metForSpeed(speedKmh)
        } else if let steps = bucket.steps, steps > 0 {
            let cadence = Double(steps) / minutes
            // No measured stride wired in yet (`strideM` already exists on the reference stream but
            // isn't connected to this model — a separate, later step). Until then: a population-
            // average adult stride, to fold cadence onto the SAME curve rather than maintaining a
            // second, independently-tuned table that can drift away from it again.
            let assumedStrideM = 0.75
            met = metForSpeed(cadence * assumedStrideM * 60 / 1_000)
        } else {
            met = motionMET(bucket)
        }
        // The strap's own classification is stronger evidence than a cadence bucket derived from a
        // motion-tick counter, so it raises a floor rather than being averaged in. It never LOWERS a
        // higher estimate: a run misreported as a walk keeps the faster distance/cadence answer.
        switch bucket.activityClass {
        case 1: met = max(met, 3.0)   // walk
        case 2: met = max(met, 7.0)   // run
        default: break
        }
        return met
    }

    /// Coarse fallback when neither distance nor cadence is available — gravity-derived motion only.
    private static func motionMET(_ bucket: WhoopEnergyBucket) -> Double {
        let motion = finite(bucket.motionIntensity) ?? 0
        return motion >= 0.20 ? 3.0 : motion >= 0.08 ? 2.0 : 1.5
    }

    /// Metabolic cost above rest for a whole bucket, in kcal. One conversion site so the HR,
    /// movement and corroborated paths can never drift apart on the MET→kcal arithmetic.
    private static func activeKcal(met: Double, seconds: Int, weightKg: Double) -> Double {
        max(0, met - 1) * 3.5 * weightKg / 200 * (Double(seconds) / 60)
    }

    /// Continuous exercise curve. Context selection happens before this function, so there is no
    /// 50%-HRR branch and therefore no one-bpm discontinuity.
    private static func workoutMET(hr: Double, resting: Double, maximum: Double,
                                   kind: EnergyWorkoutKind) -> Double {
        let reserve = min(1, max(0, (hr - resting) / (maximum - resting)))
        let coefficient: Double
        switch kind {
        case .endurance: coefficient = 11
        case .resistance: coefficient = 8
        case .other: coefficient = 9.5
        }
        return min(14.5, 1 + coefficient * reserve * reserve)
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
