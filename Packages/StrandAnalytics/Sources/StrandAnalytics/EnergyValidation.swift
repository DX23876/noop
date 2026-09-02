import Foundation

/// One externally labelled energy interval. Ground truth is expected to come from indirect
/// calorimetry; Apple Watch is a secondary comparator, never the label used to train WHOOP v4.
public struct EnergyValidationSample: Equatable, Sendable {
    public enum Cohort: String, Codable, Equatable, Sendable { case development, holdout }

    public let cohort: Cohort
    public let participantID: String
    public let context: EnergyContext
    public let groundTruthKcal: Double
    public let noopKcal: Double
    public let appleWatchKcal: Double?
    public let noopIntervalKcal: ClosedRange<Double>?

    public init(cohort: Cohort, participantID: String, context: EnergyContext,
                groundTruthKcal: Double, noopKcal: Double, appleWatchKcal: Double? = nil,
                noopIntervalKcal: ClosedRange<Double>? = nil) {
        self.cohort = cohort
        self.participantID = participantID
        self.context = context
        self.groundTruthKcal = groundTruthKcal
        self.noopKcal = noopKcal
        self.appleWatchKcal = appleWatchKcal
        self.noopIntervalKcal = noopIntervalKcal
    }
}

public struct EnergyValidationMetrics: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let participantCount: Int
    public let groundTruthKcal: Double
    public let meanAbsoluteErrorKcal: Double
    /// Sum absolute error / sum ground truth. Unlike per-bucket MAPE this remains defined for small
    /// resting-energy windows and cannot be dominated by one near-zero denominator.
    public let weightedAbsolutePercentageError: Double
    /// Sum signed error / sum ground truth. Positive means the device overestimated expenditure.
    public let meanBiasFraction: Double
    public let intervalCoverage: Double?
}

public struct EnergyValidationContextReport: Codable, Equatable, Sendable {
    public let context: EnergyContext
    public let noop: EnergyValidationMetrics
    public let appleWatch: EnergyValidationMetrics?
}

public struct EnergyValidationReport: Codable, Equatable, Sendable {
    public let holdoutSampleCount: Int
    public let noop: EnergyValidationMetrics?
    public let appleWatch: EnergyValidationMetrics?
    public let contexts: [EnergyValidationContextReport]
    public let passedReleaseGate: Bool
    public let blockingReasons: [String]
}

/// Pre-registered acceptance policy for a held-out calorimetry study. Thresholds are product release
/// criteria, not claims about Apple Watch or WHOOP accuracy. The model remains experimental until a
/// real, participant-held-out dataset makes every reason disappear.
public struct EnergyValidationPolicy: Equatable, Sendable {
    public let minimumParticipants: Int
    public let minimumSamplesPerRequiredContext: Int
    public let requiredContexts: [EnergyContext]
    public let maximumOverallWAPE: Double
    public let maximumAbsoluteBias: Double
    public let maximumContextWAPE: Double
    public let appleNonInferiorityMargin: Double
    public let acceptableIntervalCoverage: ClosedRange<Double>

    public static let release = EnergyValidationPolicy(
        minimumParticipants: 20,
        minimumSamplesPerRequiredContext: 20,
        requiredContexts: [.sedentary, .unresolvedElevatedHR, .locomotion, .confirmedWorkout],
        maximumOverallWAPE: 0.15,
        maximumAbsoluteBias: 0.10,
        maximumContextWAPE: 0.25,
        appleNonInferiorityMargin: 0.03,
        acceptableIntervalCoverage: 0.80...0.99)
}

public enum EnergyValidation {
    /// Evaluates HOLDOUT rows only. Development rows may be kept in the same CSV for model work but
    /// can never make the release gate pass, which prevents accidental evaluation on training data.
    public static func evaluate(_ samples: [EnergyValidationSample],
                                policy: EnergyValidationPolicy = .release)
        -> EnergyValidationReport {
        let holdout = samples.filter { $0.cohort == .holdout && valid($0) }
        let noop = metrics(holdout, value: \EnergyValidationSample.noopKcal)
        let appleRows = holdout.filter { $0.appleWatchKcal != nil }
        let apple = metrics(appleRows, includeIntervals: false) { $0.appleWatchKcal ?? .nan }
        let contexts = EnergyContext.allCases.compactMap { context -> EnergyValidationContextReport? in
            let rows = holdout.filter { $0.context == context }
            guard let noopContext = metrics(rows, value: \EnergyValidationSample.noopKcal) else {
                return nil
            }
            let watchRows = rows.filter { $0.appleWatchKcal != nil }
            return .init(context: context, noop: noopContext,
                         appleWatch: metrics(watchRows, includeIntervals: false) {
                            $0.appleWatchKcal ?? .nan
                         })
        }

        var reasons: [String] = []
        let participants = Set(holdout.map(\.participantID)).count
        if participants < policy.minimumParticipants {
            reasons.append("holdout participants \(participants)/\(policy.minimumParticipants)")
        }
        for required in policy.requiredContexts {
            let count = holdout.lazy.filter { $0.context == required }.count
            if count < policy.minimumSamplesPerRequiredContext {
                reasons.append("\(required.rawValue) samples \(count)/\(policy.minimumSamplesPerRequiredContext)")
            }
        }
        guard let noop else {
            reasons.append("no valid holdout calorimetry rows")
            return .init(holdoutSampleCount: holdout.count, noop: nil, appleWatch: apple,
                         contexts: contexts, passedReleaseGate: false,
                         blockingReasons: reasons.sorted())
        }
        if noop.weightedAbsolutePercentageError > policy.maximumOverallWAPE {
            reasons.append("NOOP overall WAPE exceeds \(percent(policy.maximumOverallWAPE))")
        }
        if abs(noop.meanBiasFraction) > policy.maximumAbsoluteBias {
            reasons.append("NOOP absolute bias exceeds \(percent(policy.maximumAbsoluteBias))")
        }
        for row in contexts where policy.requiredContexts.contains(row.context) {
            if row.noop.weightedAbsolutePercentageError > policy.maximumContextWAPE {
                reasons.append("NOOP \(row.context.rawValue) WAPE exceeds \(percent(policy.maximumContextWAPE))")
            }
        }
        if appleRows.count != holdout.count {
            reasons.append("Apple Watch comparator missing for \(holdout.count - appleRows.count) holdout rows")
        } else if let apple,
                  noop.weightedAbsolutePercentageError
                    > apple.weightedAbsolutePercentageError + policy.appleNonInferiorityMargin {
            reasons.append("NOOP is outside the Apple Watch non-inferiority margin")
        }
        if let coverage = noop.intervalCoverage {
            if !policy.acceptableIntervalCoverage.contains(coverage) {
                reasons.append("NOOP interval coverage \(percent(coverage)) is outside the registered range")
            }
        } else {
            reasons.append("NOOP uncertainty intervals missing")
        }
        return .init(holdoutSampleCount: holdout.count, noop: noop, appleWatch: apple,
                     contexts: contexts, passedReleaseGate: reasons.isEmpty,
                     blockingReasons: reasons.sorted())
    }

    private static func valid(_ sample: EnergyValidationSample) -> Bool {
        !sample.participantID.isEmpty && sample.groundTruthKcal.isFinite
            && sample.groundTruthKcal > 0 && sample.noopKcal.isFinite && sample.noopKcal >= 0
            && (sample.appleWatchKcal.map { $0.isFinite && $0 >= 0 } ?? true)
            && (sample.noopIntervalKcal.map {
                $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound >= 0
                    && $0.lowerBound <= $0.upperBound
            } ?? true)
    }

    private static func metrics(_ samples: [EnergyValidationSample],
                                includeIntervals: Bool = true,
                                value: (EnergyValidationSample) -> Double)
        -> EnergyValidationMetrics? {
        guard !samples.isEmpty else { return nil }
        let truth = samples.reduce(0) { $0 + $1.groundTruthKcal }
        guard truth > 0 else { return nil }
        let errors = samples.map { value($0) - $0.groundTruthKcal }
        guard errors.allSatisfy(\.isFinite) else { return nil }
        let absolute = errors.reduce(0) { $0 + abs($1) }
        let intervals = includeIntervals ? samples.compactMap(\.noopIntervalKcal) : []
        let coverage = includeIntervals && intervals.count == samples.count
            ? Double(zip(samples, intervals).lazy.filter {
                $0.1.contains($0.0.groundTruthKcal)
            }.count) / Double(samples.count)
            : nil
        return .init(sampleCount: samples.count,
                     participantCount: Set(samples.map(\.participantID)).count,
                     groundTruthKcal: truth,
                     meanAbsoluteErrorKcal: absolute / Double(samples.count),
                     weightedAbsolutePercentageError: absolute / truth,
                     meanBiasFraction: errors.reduce(0, +) / truth,
                     intervalCoverage: coverage)
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
