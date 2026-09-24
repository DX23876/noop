import Foundation

// MARK: - A training-based VO₂max, as an experimental instrument
//
// NOOP's weekly VO₂max (`vo2max_est`) is a NON-exercise estimate — Nes 2011 from an activity index,
// Uth 2004 from resting heart rate — and neither can be performance evidence (`CardioEvidence`). This
// file estimates VO₂max from what the wearer actually did: how fast they moved on foot and what heart
// rate it cost them.
//
// THE METHOD, as published, with one stated departure:
//
//   1. Oxygen cost of the session's speed — the ACSM metabolic equations (ACSM's Guidelines for
//      Exercise Testing and Prescription), speed S in m/min, grade G as a fraction:
//        walking  VO₂ = 0.1·S + 1.8·S·G + 3.5     valid for 50–100 m/min
//        running  VO₂ = 0.2·S + 0.9·S·G + 3.5     valid above 134 m/min
//      Between 100 and 134 m/min the gait decides which equation applies, and NOOP cannot see the gait,
//      so those sessions are left out rather than guessed.
//   2. Extrapolation to maximum — the percentage of heart-rate reserve equals the percentage of VO₂
//      reserve (Swain & Leutholtz 1997), so
//        VO₂max = 3.5 + (VO₂ − 3.5) / ((HR − HRrest) / (HRmax − HRrest))
//
// THE DEPARTURE: grade is taken as zero. NOOP keeps routes as polylines without altitude and has no
// per-minute speed, so a session's average speed over its whole duration stands in for a steady pace
// on the flat. Hills make the estimate read low, stops make it read low, warm-up makes it read high.
// Every surface says "grade assumed flat" beside the number.
//
// THE STATUS: an instrument, behind a default-off Experimental switch, never performance evidence. It
// may enter the evidence chain only once `validate` passes the rule fixed here in advance (CLAUDE.md:
// a derived signal must be shown to track a varying input, not to match once).

public enum ExerciseVO2max {

    /// Resting oxygen uptake, ml/kg/min — the 3.5 in both ACSM equations and in the extrapolation.
    public static let restingVO2 = 3.5
    /// Walking equation range, m/min (3.0–6.0 km/h).
    public static let walkingSpeedRange: ClosedRange<Double> = 50...100
    /// Running equation lower bound, m/min (8.04 km/h, 5 mph).
    public static let runningMinimumSpeed = 134.0
    /// Shorter sessions are dominated by the ramp in and out of the effort.
    public static let minimumMinutes = 20.0
    /// The share of heart-rate reserve over which heart rate and oxygen uptake rise linearly enough to
    /// extrapolate from. Below it heart rate is noisy against a small reserve; above it the relation
    /// bends and cardiac drift dominates.
    public static let intensityRange: ClosedRange<Double> = 0.40...0.85

    public enum Gait: String, Equatable, Sendable, Codable {
        case walking, running
    }

    /// Why a session gave no estimate.
    public enum Exclusion: String, Equatable, Sendable, Codable, CaseIterable {
        case notOnFoot
        case noDistance
        case tooShort
        /// 100–134 m/min: walking or running, which NOOP cannot tell.
        case speedBetweenGaits
        case speedOutOfRange
        /// No measured heart-rate trace, or no average heart rate.
        case heartRateNotMeasured
        case intensityOutOfRange
        case invalidHeartRateBounds
    }

    /// One session as the estimator reads it.
    public struct SessionInput: Equatable, Sendable {
        public let day: String
        public let startTs: Int
        public let modality: CardioModality
        public let distanceM: Double?
        public let durationS: Double?
        public let averageHR: Double?
        /// True when the session's heart rate came from a measured trace (band or watch), not an
        /// average-only estimate.
        public let heartRateMeasured: Bool
        public let restingHR: Double
        public let maxHR: Double

        public init(day: String, startTs: Int, modality: CardioModality, distanceM: Double?, durationS: Double?,
                    averageHR: Double?, heartRateMeasured: Bool, restingHR: Double, maxHR: Double) {
            self.day = day; self.startTs = startTs; self.modality = modality
            self.distanceM = distanceM; self.durationS = durationS; self.averageHR = averageHR
            self.heartRateMeasured = heartRateMeasured; self.restingHR = restingHR; self.maxHR = maxHR
        }
    }

    public struct SessionEstimate: Equatable, Sendable {
        public let day: String
        public let startTs: Int
        public let gait: Gait
        public let speedMPerMin: Double
        /// (HR − HRrest) / (HRmax − HRrest).
        public let fractionOfReserve: Double
        /// The session's oxygen cost, ml/kg/min.
        public let vo2: Double
        public let vo2max: Double
    }

    public enum Outcome: Equatable, Sendable {
        case estimate(SessionEstimate)
        case excluded(Exclusion)
    }

    /// One Monday–Sunday week: the median of its session estimates.
    public struct WeeklyEstimate: Equatable, Sendable {
        public let mondayKey: String
        /// The last day with an estimate in that week — what a comparison pairs by.
        public let lastDay: String
        public let value: Double
        public let sessions: Int
    }

    // MARK: - The equations

    /// The ACSM oxygen cost of moving at `speed` m/min on `grade` (a fraction), ml/kg/min.
    public static func acsmVO2(speedMPerMin speed: Double, grade: Double = 0, gait: Gait) -> Double {
        switch gait {
        case .walking: return 0.1 * speed + 1.8 * speed * grade + restingVO2
        case .running: return 0.2 * speed + 0.9 * speed * grade + restingVO2
        }
    }

    /// The equation a speed belongs to, or nil between the two ranges and outside them.
    public static func gait(speedMPerMin speed: Double) -> Gait? {
        if walkingSpeedRange.contains(speed) { return .walking }
        if speed > runningMinimumSpeed { return .running }
        return nil
    }

    /// %HRR = %VO₂R extrapolated to maximum.
    public static func extrapolate(vo2: Double, fractionOfReserve: Double) -> Double {
        restingVO2 + (vo2 - restingVO2) / fractionOfReserve
    }

    // MARK: - One session

    public static func estimate(_ input: SessionInput) -> Outcome {
        guard input.modality == .foot else { return .excluded(.notOnFoot) }
        guard let distance = input.distanceM, distance > 0 else { return .excluded(.noDistance) }
        guard let seconds = input.durationS, seconds / 60 >= minimumMinutes else { return .excluded(.tooShort) }
        let speed = distance / (seconds / 60)
        guard let gait = gait(speedMPerMin: speed) else {
            return .excluded(speed > walkingSpeedRange.upperBound && speed <= runningMinimumSpeed
                             ? .speedBetweenGaits : .speedOutOfRange)
        }
        guard input.heartRateMeasured, let hr = input.averageHR, hr > 0 else {
            return .excluded(.heartRateNotMeasured)
        }
        guard input.maxHR > input.restingHR, input.restingHR > 0 else { return .excluded(.invalidHeartRateBounds) }
        let fraction = (hr - input.restingHR) / (input.maxHR - input.restingHR)
        guard intensityRange.contains(fraction) else { return .excluded(.intensityOutOfRange) }
        let vo2 = acsmVO2(speedMPerMin: speed, gait: gait)
        return .estimate(SessionEstimate(day: input.day, startTs: input.startTs, gait: gait, speedMPerMin: speed,
                                         fractionOfReserve: fraction, vo2: vo2,
                                         vo2max: extrapolate(vo2: vo2, fractionOfReserve: fraction)))
    }

    // MARK: - Weeks

    /// The median estimate of each Monday–Sunday week that has one, oldest first.
    public static func weekly(_ estimates: [SessionEstimate]) -> [WeeklyEstimate] {
        var byWeek: [String: [SessionEstimate]] = [:]
        for estimate in estimates {
            byWeek[mondayKey(estimate.day), default: []].append(estimate)
        }
        return byWeek.keys.sorted().compactMap { monday in
            guard let week = byWeek[monday], let value = median(week.map(\.vo2max)),
                  let last = week.map(\.day).max() else { return nil }
            return WeeklyEstimate(mondayKey: monday, lastDay: last, value: value, sessions: week.count)
        }
    }

    // MARK: - Validation (fixed before looking at any data)

    /// Week pairs with an Apple Watch reading needed before a verdict on the instrument.
    public static let validationMinimumPairs = 8
    /// The largest mean absolute difference from Apple's measured VO₂max that passes, ml/kg/min.
    public static let validationMaximumError = 3.5
    /// The share of week-to-week changes whose direction must agree with Apple's.
    public static let validationMinimumAgreement = 0.70
    /// How far apart an estimate and an Apple reading may be to form a pair.
    public static let validationPairingDays = 7
    /// Apple changes smaller than this are not counted as a direction.
    public static let validationMinimumAppleChange = 0.5

    public struct ValidationReport: Equatable, Sendable {
        public let pairs: Int
        public let meanAbsoluteError: Double?
        /// Consecutive pairs whose Apple change was large enough to have a direction.
        public let directionSteps: Int
        public let directionAgreement: Double?
        public let passes: Bool
    }

    /// Pairs each weekly estimate with the nearest Apple reading within `validationPairingDays` and applies
    /// the rule: enough pairs, a small mean error, and changes that move with Apple's. Both conditions
    /// matter — a level that matches once is not an instrument that tracks (CLAUDE.md).
    public static func validate(weekly: [WeeklyEstimate], apple: [VO2maxReading]) -> ValidationReport {
        let readings = apple.filter { $0.value > 0 }
        var pairs: [(estimate: Double, apple: Double)] = []
        for week in weekly {
            let nearest = readings
                .map { ($0, StrengthSession.daysBetween(min($0.day, week.lastDay), and: max($0.day, week.lastDay))) }
                .filter { $0.1 <= validationPairingDays }
                .min { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.day < $1.0.day }
            if let nearest { pairs.append((week.value, nearest.0.value)) }
        }
        let mae = pairs.isEmpty ? nil : pairs.map { abs($0.estimate - $0.apple) }.reduce(0, +) / Double(pairs.count)
        var steps = 0
        var agreeing = 0
        for index in pairs.indices.dropFirst() {
            let appleChange = pairs[index].apple - pairs[index - 1].apple
            guard abs(appleChange) >= validationMinimumAppleChange else { continue }
            steps += 1
            let estimateChange = pairs[index].estimate - pairs[index - 1].estimate
            if (appleChange > 0) == (estimateChange > 0) && estimateChange != 0 { agreeing += 1 }
        }
        let agreement = steps > 0 ? Double(agreeing) / Double(steps) : nil
        let passes = pairs.count >= validationMinimumPairs
            && (mae ?? .infinity) <= validationMaximumError
            && (agreement ?? 0) >= validationMinimumAgreement
        return ValidationReport(pairs: pairs.count, meanAbsoluteError: mae, directionSteps: steps,
                                directionAgreement: agreement, passes: passes)
    }

    // MARK: - Helpers

    private static func mondayKey(_ day: String) -> String {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(day),
              let weekday = WeeklyDigestEngine.weekday(y, m, d) else { return day }
        // Sakamoto: 0 = Sunday … 6 = Saturday; Monday-anchored like every other NOOP week.
        return WeeklyDigestEngine.addDays(day, -((weekday + 6) % 7))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
