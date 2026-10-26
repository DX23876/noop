import Foundation
import StrandAnalytics
import StrandTraining
import WhoopStore

/// The three muscle readings of the Training tab's muscle analytics (balance, fatigue, strength), computed from the
/// resolved strength history and the wearer's soreness answers. One implementation for the Apple model and the Android
/// core (`CoreTraining.snapshot`, parity plan 1.2), so both platforms shade the same body.
struct MuscleAnalyticsSnapshot: Sendable {
    let balance: MuscleBalanceResult
    let fatigue: MuscleFatigueResult
    let strength: MuscleStrengthResult

    /// The stored soreness answers as the recovery fit reads them; an answer outside the scale is skipped.
    static func observations(_ rows: [MuscleRecoveryFeedback]) -> [MuscleRecovery.Observation] {
        rows.compactMap { row in
            MuscleRecovery.Feeling(rawValue: row.feeling).map {
                .init(group: row.muscleGroup, ts: row.ts, feeling: $0)
            }
        }
    }

    static func compute(history: ResolvedStrengthHistory, observations: [MuscleRecovery.Observation],
                        now: Int) -> MuscleAnalyticsSnapshot {
        let evidence = history.muscleMetricSets()
        let index = MuscleStimulus.SessionStimulusIndex(workouts: history.workouts, templates: history.templates)
        let typical = MuscleRecovery.typicalSessionStimulus(index: index)
        var tauByGroup: [HevyMuscleGroup: Double] = [:]
        var fittedGroups = Set<HevyMuscleGroup>()
        for group in HevyMuscleGroup.allCases {
            let count = observations.filter { $0.group == group }.count
            tauByGroup[group] = MuscleRecovery.fittedTauSeconds(
                for: group, observations: observations, index: index, typicalSession: typical)
            if count >= 2 { fittedGroups.insert(group) }
        }
        var tauByMuscle: [String: Double] = [:]
        var fittedMuscles = Set<String>()
        for muscle in TrainingMuscleCatalog.all {
            let group = HevyMuscleGroup.forTrainingMuscle(muscle.id)
            tauByMuscle[muscle.id] = tauByGroup[group] ?? MuscleRecovery.defaultTauSeconds(for: group)
            if fittedGroups.contains(group) { fittedMuscles.insert(muscle.id) }
        }
        return MuscleAnalyticsSnapshot(
            balance: MuscleBalanceMetric.calculate(sets: evidence, now: now,
                                                   historyAvailableFrom: history.historyAvailableFrom),
            fatigue: MuscleFatigueMetric.calculate(sets: evidence, now: now, tauByMuscle: tauByMuscle,
                                                   personallyFittedMuscles: fittedMuscles),
            strength: MuscleStrengthMetric.calculate(sets: evidence))
    }
}
