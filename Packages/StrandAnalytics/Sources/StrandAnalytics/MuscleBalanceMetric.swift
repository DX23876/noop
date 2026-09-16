import Foundation

public enum MuscleBalanceState: String, Equatable, Sendable {
    case belowUsual
    case withinUsualVariation
    case aboveUsual
    case baselineGrowing
}

public struct MuscleBalanceReading: Equatable, Sendable, Identifiable {
    public let muscleId: String
    public let effectiveSets: Double
    public let distributionShare: Double
    public let usualShare: Double?
    public let usualMAD: Double?
    public let state: MuscleBalanceState
    public let evidence: [MuscleMetricEvidence]

    public var id: String { muscleId }
}

public struct MuscleBalanceResult: Equatable, Sendable {
    public let readings: [MuscleBalanceReading]
    public let coverage: MuscleMetricCoverage
    public let hasPersonalBaseline: Bool
    public let currentWindowDays: Int
}

/// Distribution of effective working sets. It compares each muscle only with the wearer's own prior
/// distribution and deliberately defines no universal ideal physique or push/pull ratio.
public enum MuscleBalanceMetric {
    public static let currentWindowDays = 28
    public static let baselineWeeks = 8

    public static func calculate(sets: [MuscleMetricSet], now: Int,
                                 historyAvailableFrom: Int? = nil) -> MuscleBalanceResult {
        let currentFrom = now - currentWindowDays * 86_400
        let work = sets.filter { !$0.isWarmup && $0.startTs >= currentFrom && $0.startTs <= now }
        let coverage = MuscleMetricMath.coverage(work)
        let current = totals(work)
        let currentTotal = current.values.reduce(0, +)

        let baselineEnd = currentFrom
        let baselineStart = baselineEnd - baselineWeeks * 7 * 86_400
        let hasSpan = historyAvailableFrom.map { $0 <= baselineStart } ?? false
        var weeklyShares: [[String: Double]] = []
        if hasSpan {
            for week in 0..<baselineWeeks {
                let end = baselineEnd - week * 7 * 86_400
                let start = end - 7 * 86_400
                let values = totals(sets.filter {
                    !$0.isWarmup && $0.startTs >= start && $0.startTs < end
                })
                let total = values.values.reduce(0, +)
                weeklyShares.append(total > 0 ? values.mapValues { $0 / total } : [:])
            }
        }

        let muscleIds = Set(current.keys).union(weeklyShares.flatMap(\.keys))
        var readings: [MuscleBalanceReading] = []
        readings.reserveCapacity(muscleIds.count)
        for muscleId in muscleIds {
            let share = currentTotal > 0 ? (current[muscleId] ?? 0) / currentTotal : 0
            let samples = weeklyShares.map { $0[muscleId] ?? 0 }
            let usual = MuscleMetricMath.median(samples)
            let mad = usual.flatMap { center in
                MuscleMetricMath.median(samples.map { abs($0 - center) })
            }
            let state: MuscleBalanceState
            if let usual, let mad, hasSpan {
                // Two MADs are used as a robust descriptive band. A small floor prevents a perfectly
                // repeated zero from turning the first incidental set into false precision.
                let spread = max(0.01, 2 * mad)
                if share < usual - spread { state = .belowUsual }
                else if share > usual + spread { state = .aboveUsual }
                else { state = .withinUsualVariation }
            } else {
                state = .baselineGrowing
            }
            let muscleEvidence = evidence(for: muscleId, in: work)
            let reading = MuscleBalanceReading(
                muscleId: muscleId,
                effectiveSets: current[muscleId] ?? 0,
                distributionShare: share,
                usualShare: usual,
                usualMAD: mad,
                state: state,
                evidence: muscleEvidence)
            readings.append(reading)
        }
        readings.sort {
            $0.effectiveSets == $1.effectiveSets ? $0.muscleId < $1.muscleId
                : $0.effectiveSets > $1.effectiveSets
        }
        return .init(readings: readings, coverage: coverage,
                     hasPersonalBaseline: hasSpan, currentWindowDays: currentWindowDays)
    }

    private static func totals(_ sets: [MuscleMetricSet]) -> [String: Double] {
        var result: [String: Double] = [:]
        for set in sets {
            for credit in set.muscleCredits {
                result[credit.id, default: 0] += set.stimulus * credit.share
            }
        }
        return result
    }

    private static func evidence(for muscleId: String,
                                 in sets: [MuscleMetricSet]) -> [MuscleMetricEvidence] {
        let rows: [MuscleMetricEvidence] = sets.compactMap { set in
            guard let credit = set.muscleCredits.first(where: { $0.id == muscleId }) else {
                return nil
            }
            return .init(sessionId: set.sessionId, sessionTitle: set.sessionTitle,
                         exerciseId: set.exerciseId, exerciseTitle: set.exerciseTitle,
                         startTs: set.startTs, value: set.stimulus * credit.share,
                         isPrimary: credit.isPrimary)
        }
        return MuscleMetricMath.aggregatedEvidence(rows)
    }
}
