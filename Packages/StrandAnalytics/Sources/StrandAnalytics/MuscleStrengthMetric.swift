import Foundation

public enum MuscleStrengthDirection: String, Equatable, Sendable {
    case increasing
    case decreasing
    case stable
    case unclear
    case insufficientEvidence
}

public struct MuscleStrengthExerciseEvidence: Equatable, Sendable, Identifiable {
    public let exerciseId: String
    public let exerciseTitle: String
    public let pointCount: Int
    public let normalizedSlopePerWeek: Double?
    public let directionIsUnclear: Bool
    public let isPrimary: Bool

    public var id: String { "\(exerciseId)|\(isPrimary)" }
}

public struct MuscleStrengthReading: Equatable, Sendable, Identifiable {
    public let muscleId: String
    public let normalizedSlopePerWeek: Double?
    public let direction: MuscleStrengthDirection
    public let exerciseEvidence: [MuscleStrengthExerciseEvidence]

    public var id: String { muscleId }
}

public struct MuscleStrengthResult: Equatable, Sendable {
    public let readings: [MuscleStrengthReading]
    public let coverage: MuscleMetricCoverage
}

/// A cross-muscle view of exercise trends. Every lift is first normalized against its own e1RM history;
/// kilograms from different exercises are never added or compared directly.
public enum MuscleStrengthMetric {
    public static func calculate(sets: [MuscleMetricSet]) -> MuscleStrengthResult {
        let work = sets.filter { !$0.isWarmup }
        let byExercise = Dictionary(grouping: work, by: \.exerciseId)
        var evidenceByMuscle: [String: [MuscleStrengthExerciseEvidence]] = [:]

        for (_, exerciseSets) in byExercise {
            let bySession = Dictionary(grouping: exerciseSets, by: \.sessionId)
            let points: [ExercisePerformancePoint] = bySession.values.compactMap { sessionSets in
                guard let first = sessionSets.first else { return nil }
                let best = sessionSets.compactMap(\.estimatedOneRepMaxKg).max()
                guard let best else { return nil }
                return ExercisePerformancePoint(day: String(first.startTs), startTs: first.startTs,
                    workoutId: first.sessionId, bestE1RMKg: best, heaviestSetKg: nil,
                    workingSetCount: sessionSets.count, totalReps: 0, volumeLoadKg: 0,
                    meanRpe: nil, rpeSetCount: sessionSets.filter(\.rpeWasRecorded).count)
            }.sorted { $0.startTs < $1.startTs }
            let baseline = MuscleMetricMath.median(points.compactMap(\.bestE1RMKg))
            let line = StrengthProgress.e1rmTrend(points)
            let normalized = line.flatMap { trend in
                baseline.flatMap { $0 > 0 ? trend.slopePerWeek / $0 : nil }
            }
            guard let anatomy = exerciseSets.last else { continue }
            let primaries = Set(anatomy.primaryMuscleIds)
            let secondaries = Set(anatomy.secondaryMuscleIds).subtracting(primaries)
            for muscleId in primaries.union(secondaries) {
                evidenceByMuscle[muscleId, default: []].append(.init(
                    exerciseId: anatomy.exerciseId, exerciseTitle: anatomy.exerciseTitle,
                    pointCount: points.count, normalizedSlopePerWeek: normalized,
                    directionIsUnclear: line?.directionIsUnclear ?? true,
                    isPrimary: primaries.contains(muscleId)))
            }
        }

        let readings = evidenceByMuscle.map { muscleId, evidence -> MuscleStrengthReading in
            let clear = evidence.compactMap { item -> (value: Double, weight: Double)? in
                guard !item.directionIsUnclear, let value = item.normalizedSlopePerWeek else { return nil }
                return (value, item.isPrimary ? 1 : 0.5)
            }
            let value = MuscleMetricMath.weightedMedian(clear)
            let direction: MuscleStrengthDirection
            if let value {
                if value > 0 { direction = .increasing }
                else if value < 0 { direction = .decreasing }
                else { direction = .stable }
            } else if evidence.contains(where: { $0.pointCount >= StrengthProgress.minimumTrendPoints }) {
                direction = .unclear
            } else {
                direction = .insufficientEvidence
            }
            return .init(muscleId: muscleId, normalizedSlopePerWeek: value,
                         direction: direction,
                         exerciseEvidence: evidence.sorted {
                             $0.pointCount == $1.pointCount ? $0.exerciseTitle < $1.exerciseTitle
                                 : $0.pointCount > $1.pointCount
                         })
        }.sorted { lhs, rhs in
            let lv = abs(lhs.normalizedSlopePerWeek ?? 0)
            let rv = abs(rhs.normalizedSlopePerWeek ?? 0)
            return lv == rv ? lhs.muscleId < rhs.muscleId : lv > rv
        }
        return .init(readings: readings, coverage: MuscleMetricMath.coverage(work))
    }
}
