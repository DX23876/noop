import Foundation

/// One logged set projected onto NOOP's detailed muscle vocabulary. The source workout remains the
/// authority; this value carries only the evidence shared by the three muscle views.
public struct MuscleMetricSet: Equatable, Sendable {
    public let sessionId: String
    public let sessionTitle: String
    public let exerciseId: String
    public let exerciseTitle: String
    public let startTs: Int
    public let isWarmup: Bool
    public let rpeWasRecorded: Bool
    public let stimulus: Double
    public let estimatedOneRepMaxKg: Double?
    public let primaryMuscleIds: [String]
    public let secondaryMuscleIds: [String]
    public let stabilizerMuscleIds: [String]

    public init(sessionId: String, sessionTitle: String, exerciseId: String,
                exerciseTitle: String, startTs: Int, isWarmup: Bool,
                rpeWasRecorded: Bool, stimulus: Double, estimatedOneRepMaxKg: Double?,
                primaryMuscleIds: [String], secondaryMuscleIds: [String],
                stabilizerMuscleIds: [String] = []) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.exerciseId = exerciseId
        self.exerciseTitle = exerciseTitle
        self.startTs = startTs
        self.isWarmup = isWarmup
        self.rpeWasRecorded = rpeWasRecorded
        self.stimulus = max(0, stimulus)
        self.estimatedOneRepMaxKg = estimatedOneRepMaxKg
        self.primaryMuscleIds = Self.unique(primaryMuscleIds)
        self.secondaryMuscleIds = Self.unique(secondaryMuscleIds)
        self.stabilizerMuscleIds = Self.unique(stabilizerMuscleIds)
    }

    public var isMapped: Bool { !primaryMuscleIds.isEmpty || !secondaryMuscleIds.isEmpty }

    var muscleCredits: [(id: String, share: Double, isPrimary: Bool)] {
        let primary = Set(primaryMuscleIds)
        let secondary = Set(secondaryMuscleIds).subtracting(primary)
        return primary.sorted().map { ($0, 1, true) }
            + secondary.sorted().map { ($0, 0.5, false) }
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

/// Data quality shown beside every muscle interpretation. Unmapped work remains in the denominator
/// so a colourful body cannot hide how much of a session it omitted.
public struct MuscleMetricCoverage: Equatable, Sendable {
    public let workingSetCount: Int
    public let mappedSetCount: Int
    public let ratedSetCount: Int

    public init(workingSetCount: Int, mappedSetCount: Int, ratedSetCount: Int) {
        self.workingSetCount = workingSetCount
        self.mappedSetCount = mappedSetCount
        self.ratedSetCount = ratedSetCount
    }

    public var mappingShare: Double {
        workingSetCount > 0 ? Double(mappedSetCount) / Double(workingSetCount) : 0
    }

    public var ratingShare: Double {
        workingSetCount > 0 ? Double(ratedSetCount) / Double(workingSetCount) : 0
    }

    public var unmappedSetCount: Int { max(0, workingSetCount - mappedSetCount) }
}

public struct MuscleMetricEvidence: Equatable, Sendable, Identifiable {
    public let sessionId: String
    public let sessionTitle: String
    public let exerciseId: String
    public let exerciseTitle: String
    public let startTs: Int
    public let value: Double
    public let isPrimary: Bool

    public var id: String { "\(sessionId)|\(exerciseId)|\(startTs)|\(isPrimary)" }

    public init(sessionId: String, sessionTitle: String, exerciseId: String,
                exerciseTitle: String, startTs: Int, value: Double, isPrimary: Bool) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.exerciseId = exerciseId
        self.exerciseTitle = exerciseTitle
        self.startTs = startTs
        self.value = value
        self.isPrimary = isPrimary
    }
}

enum MuscleMetricMath {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    static func weightedMedian(_ values: [(value: Double, weight: Double)]) -> Double? {
        let sorted = values.filter { $0.value.isFinite && $0.weight > 0 }.sorted { $0.value < $1.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var cumulative = 0.0
        for item in sorted {
            cumulative += item.weight
            if cumulative >= total / 2 { return item.value }
        }
        return sorted.last?.value
    }

    static func coverage(_ sets: [MuscleMetricSet]) -> MuscleMetricCoverage {
        let work = sets.filter { !$0.isWarmup }
        return .init(workingSetCount: work.count,
                     mappedSetCount: work.filter(\.isMapped).count,
                     ratedSetCount: work.filter(\.rpeWasRecorded).count)
    }

    static func aggregatedEvidence(_ values: [MuscleMetricEvidence]) -> [MuscleMetricEvidence] {
        let grouped = Dictionary(grouping: values) {
            "\($0.sessionId)|\($0.exerciseId)|\($0.isPrimary)"
        }
        return grouped.values.compactMap { rows in
            guard let first = rows.first else { return nil }
            return .init(sessionId: first.sessionId, sessionTitle: first.sessionTitle,
                         exerciseId: first.exerciseId, exerciseTitle: first.exerciseTitle,
                         startTs: rows.map(\.startTs).max() ?? first.startTs,
                         value: rows.reduce(0) { $0 + $1.value },
                         isPrimary: first.isPrimary)
        }.sorted { lhs, rhs in
            lhs.startTs == rhs.startTs ? lhs.exerciseTitle < rhs.exerciseTitle
                : lhs.startTs > rhs.startTs
        }
    }
}
