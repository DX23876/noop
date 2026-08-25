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
    /// The strap's OWN `activity_class@63` code — 0 still / 1 walk / 2 run. A direct classification
    /// rather than something inferred from cadence, so it sets a floor the weaker signals cannot pull
    /// below. WHOOP 5/MG only: a 4.0 record carries no such field and leaves this nil.
    public let activityClass: Int?
    public let isWorkout: Bool
    public let isSleep: Bool
    public let isOffWrist: Bool

    public init(start: Int, durationSeconds: Int = 300, averageHR: Double? = nil,
                motionIntensity: Double? = nil, steps: Int? = nil, distanceM: Double? = nil,
                strideM: Double? = nil, activityClass: Int? = nil, isWorkout: Bool = false,
                isSleep: Bool = false, isOffWrist: Bool = false) {
        self.start = start
        self.durationSeconds = durationSeconds
        self.averageHR = averageHR
        self.motionIntensity = motionIntensity
        self.steps = steps
        self.distanceM = distanceM
        self.strideM = strideM
        self.activityClass = activityClass
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
    /// v2 (2026-08-25): movement corroborates the HR curve, and the strap's `activity_class` sets a
    /// MET floor. v3 (2026-08-26): the cadence and distance branches of `movementMET` now share one
    /// Compendium-referenced speed→MET curve instead of two independently-tuned tables that could
    /// disagree by up to 2.7 MET at the same real speed. Bumped rather than edited in place so every
    /// older row is recomputed on the next refresh instead of two model generations being averaged
    /// into one trend.
    public static let modelVersion = "whoop-bucket-v3"

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
                // Heart rate alone CANNOT see a walk. At ~37% HR reserve the conservative
                // low-intensity curve below returns ~1.9 MET where a brisk walk really costs 3.0-4.3,
                // and the day path it replaced was worse still: `Calories.estimateDayCalories` gates
                // the Keytel rate at 50% HRR and credits every second below it the bare resting rate,
                // so a whole 30-minute walk contributed EXACTLY zero active energy (the resting rate
                // and `EnergyEngine`'s basal top-up are the same number, so they cancel).
                //
                // So when the strap ALSO reports movement for this same bucket, take whichever model
                // reads higher. `max` is what keeps this honest in both directions: movement can only
                // ever RAISE the estimate, only when a real steps / distance / motion / activity-class
                // signal corroborates it, and a high-HR low-motion bucket (cycling, lifting) keeps the
                // HR curve untouched. Evidence stays `.observed` — HR was measured here; the movement
                // channel corroborates that measurement rather than standing in for it.
                let met = max(hrMET(hr: hr, restingHR: restingHR, maxHR: maxHR,
                                    workout: bucket.isWorkout),
                              hasMovement(bucket) ? movementMET(bucket) : 0)
                result = .init(start: bucket.start,
                               kcal: basal + activeKcal(met: met, seconds: seconds,
                                                        weightKg: profile.weightKg),
                               evidence: .observed)
                observed += seconds
            } else if hasMovement(bucket) {
                let met = movementMET(bucket)
                result = .init(start: bucket.start,
                               kcal: basal + activeKcal(met: met, seconds: seconds,
                                                        weightKg: profile.weightKg),
                               evidence: .inferred)
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
        let minutes = max(1.0 / 60, Double(bucket.durationSeconds) / 60)
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

    /// The heart-rate model's own MET, before any movement corroboration.
    private static func hrMET(hr: Double, restingHR: Double?, maxHR: Double?,
                              workout: Bool) -> Double {
        let resting = min(100, max(35, restingHR ?? 60))
        let maximum = max(resting + 20, maxHR ?? 190)
        let reserve = min(1, max(0, (hr - resting) / (maximum - resting)))
        // HR alone is noisy at low intensity. Only genuine workout/high-HRR buckets receive the
        // steep exercise curve; other HR buckets remain a conservative low-intensity estimate.
        if workout || reserve >= 0.50 {
            return min(14, 1 + 11 * reserve * reserve)
        }
        return 1 + 2.5 * reserve
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
