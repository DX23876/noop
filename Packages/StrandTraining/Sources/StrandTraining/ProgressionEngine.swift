import Foundation

public struct ProgressionSession: Codable, Equatable, Sendable {
    public let weightKg: Double?
    public let completedReps: [Int]
    public let targetReps: [Int]
    public let durationS: Int?
    public let targetDurationS: Int?
    public let workSetCount: Int

    public init(weightKg: Double?, completedReps: [Int], targetReps: [Int],
                durationS: Int? = nil, targetDurationS: Int? = nil,
                workSetCount: Int? = nil) {
        self.weightKg = weightKg
        self.completedReps = completedReps
        self.targetReps = targetReps
        self.durationS = durationS
        self.targetDurationS = targetDurationS
        self.workSetCount = workSetCount ?? completedReps.count
    }

    public var succeeded: Bool {
        if let durationS, let targetDurationS { return durationS >= targetDurationS }
        guard !targetReps.isEmpty, completedReps.count >= targetReps.count else { return false }
        return zip(completedReps, targetReps).allSatisfy(>=)
    }
}

public enum ProgressionReason: String, Codable, CaseIterable, Sendable {
    case disabled
    case firstSession = "first_session"
    case repeatTarget = "repeat_target"
    case successfulSession = "successful_session"
    case topOfRepRange = "top_of_rep_range"
    case exceptionalAMRAP = "exceptional_amrap"
    case stalledDeload = "stalled_deload"
    case addRepetition = "add_repetition"
    case addSet = "add_set"
    case addLoadOrVariation = "add_load_or_variation"
    case addTime = "add_time"
}

public struct ProgressionPrescription: Codable, Equatable, Sendable {
    public let weightKg: Double?
    public let reps: Int?
    public let setCount: Int?
    public let durationS: Int?
    public let reason: ProgressionReason

    public init(weightKg: Double? = nil, reps: Int? = nil, setCount: Int? = nil,
                durationS: Int? = nil, reason: ProgressionReason) {
        self.weightKg = weightKg
        self.reps = reps
        self.setCount = setCount
        self.durationS = durationS
        self.reason = reason
    }
}

public enum TrainingProgressionEngine {
    public static func next(configuration c: ProgressionConfiguration,
                            history: [ProgressionSession], mode: TrainingMeasurementMode,
                            currentWeightKg: Double? = nil, currentReps: Int? = nil,
                            currentSets: Int? = nil, currentDurationS: Int? = nil) -> ProgressionPrescription {
        guard c.policy != .off else {
            return .init(weightKg: currentWeightKg, reps: currentReps, setCount: currentSets,
                         durationS: currentDurationS, reason: .disabled)
        }
        guard let last = history.last else {
            return .init(weightKg: currentWeightKg, reps: currentReps, setCount: currentSets,
                         durationS: currentDurationS, reason: .firstSession)
        }

        let failures = history.reversed().prefix { !$0.succeeded }.count
        if failures >= c.failuresBeforeDeload, let weight = last.weightKg ?? currentWeightKg {
            return .init(weightKg: snap(weight * c.deloadFactor, step: c.weightIncrementKg),
                         reps: c.repsMin, setCount: currentSets, reason: .stalledDeload)
        }

        if mode == .bodyweightReps {
            let reps = last.completedReps.min() ?? currentReps ?? c.repsMin
            let sets = max(1, last.workSetCount)
            guard last.succeeded else {
                return .init(reps: reps, setCount: sets, reason: .repeatTarget)
            }
            if reps < c.repsMax {
                return .init(reps: reps + 1, setCount: sets, reason: .addRepetition)
            }
            if sets < c.bodyweightMaxSets {
                return .init(reps: c.repsMin, setCount: sets + 1, reason: .addSet)
            }
            return .init(reps: reps, setCount: sets, reason: .addLoadOrVariation)
        }

        switch c.policy {
        case .off:
            return .init(reason: .disabled)
        case .time:
            let duration = last.durationS ?? currentDurationS ?? 0
            return last.succeeded
                ? .init(durationS: duration + c.durationIncrementS, reason: .addTime)
                : .init(durationS: duration, reason: .repeatTarget)
        case .linear:
            let weight = last.weightKg ?? currentWeightKg
            return last.succeeded
                ? .init(weightKg: weight.map { snap($0 + c.weightIncrementKg, step: c.weightIncrementKg) },
                        reps: currentReps, setCount: currentSets, reason: .successfulSession)
                : .init(weightKg: weight, reps: currentReps, setCount: currentSets, reason: .repeatTarget)
        case .doubleProgression:
            let reps = last.completedReps.min() ?? currentReps ?? c.repsMin
            let weight = last.weightKg ?? currentWeightKg
            guard last.succeeded else {
                return .init(weightKg: weight, reps: max(c.repsMin, reps), setCount: currentSets,
                             reason: .repeatTarget)
            }
            if reps >= c.repsMax {
                return .init(weightKg: weight.map { snap($0 + c.weightIncrementKg, step: c.weightIncrementKg) },
                             reps: c.repsMin, setCount: currentSets, reason: .topOfRepRange)
            }
            return .init(weightKg: weight, reps: reps + 1, setCount: currentSets,
                         reason: .addRepetition)
        case .greyskullLP:
            let weight = last.weightKg ?? currentWeightKg
            guard last.succeeded else {
                return .init(weightKg: weight, reps: currentReps, setCount: currentSets,
                             reason: .repeatTarget)
            }
            let amrap = last.completedReps.last ?? 0
            let target = last.targetReps.last ?? c.repsMin
            let multiplier = amrap >= target + 5 ? 2.0 : 1.0
            return .init(weightKg: weight.map {
                snap($0 + c.weightIncrementKg * multiplier, step: c.weightIncrementKg)
            }, reps: currentReps, setCount: currentSets,
                         reason: multiplier > 1 ? .exceptionalAMRAP : .successfulSession)
        }
    }

    public static func snap(_ value: Double, step: Double) -> Double {
        guard value.isFinite, step.isFinite, step > 0 else { return value }
        return max(0, (value / step).rounded() * step)
    }
}
