import Foundation

public struct MuscleFatigueReading: Equatable, Sendable, Identifiable {
    public let muscleId: String
    public let residualStimulus: Double
    public let relativeToTypicalSession: Double
    public let tauSeconds: Double
    public let usesPersonalTau: Bool
    public let evidence: [MuscleMetricEvidence]

    public var id: String { muscleId }
}

public struct MuscleFatigueResult: Equatable, Sendable {
    public let readings: [MuscleFatigueReading]
    public let coverage: MuscleMetricCoverage
}

/// Residual estimated stimulus, not measured recovery. The caller supplies the same default or fitted
/// decay constants used by NOOP's established recovery model.
public enum MuscleFatigueMetric {
    /// Eight time constants leave less than 0.04% of a session's original contribution.
    static let decayHorizonMultiples = 8.0

    public static func calculate(sets: [MuscleMetricSet], now: Int,
                                 tauByMuscle: [String: Double],
                                 personallyFittedMuscles: Set<String> = []) -> MuscleFatigueResult {
        let longestTau = max(72 * 3_600, tauByMuscle.values.max() ?? 0)
        let cutoff = now - Int(longestTau * decayHorizonMultiples)
        let work = sets.filter { !$0.isWarmup && $0.startTs >= cutoff && $0.startTs <= now }
        var residual: [String: Double] = [:]
        var sessionTotals: [String: [String: Double]] = [:]
        var evidenceByMuscle: [String: [MuscleMetricEvidence]] = [:]

        for set in work {
            for credit in set.muscleCredits {
                let muscleId = credit.id
                let share = credit.share
                let tau = max(3_600, tauByMuscle[muscleId] ?? 72 * 3_600)
                let value = set.stimulus * share
                residual[muscleId, default: 0] += value * exp(-Double(now - set.startTs) / tau)
                sessionTotals[muscleId, default: [:]][set.sessionId, default: 0] += value
                evidenceByMuscle[muscleId, default: []].append(.init(
                    sessionId: set.sessionId, sessionTitle: set.sessionTitle,
                    exerciseId: set.exerciseId, exerciseTitle: set.exerciseTitle,
                    startTs: set.startTs, value: value, isPrimary: credit.isPrimary))
            }
        }

        var readings: [MuscleFatigueReading] = []
        readings.reserveCapacity(residual.count)
        for (muscleId, value) in residual {
            let sessions = sessionTotals[muscleId] ?? [:]
            let typical = MuscleMetricMath.median(Array(sessions.values)) ?? 0
            let relative = typical > 0 ? min(1, value / typical) : 0
            let tau = max(3_600, tauByMuscle[muscleId] ?? 72 * 3_600)
            let evidence = MuscleMetricMath.aggregatedEvidence(evidenceByMuscle[muscleId] ?? [])
            let reading = MuscleFatigueReading(
                muscleId: muscleId,
                residualStimulus: value,
                relativeToTypicalSession: relative,
                tauSeconds: tau,
                usesPersonalTau: personallyFittedMuscles.contains(muscleId),
                evidence: evidence)
            readings.append(reading)
        }
        readings.sort {
            $0.residualStimulus == $1.residualStimulus ? $0.muscleId < $1.muscleId
                : $0.residualStimulus > $1.residualStimulus
        }
        return .init(readings: readings, coverage: MuscleMetricMath.coverage(work))
    }
}
