import Foundation
import StrandAnalytics
import StrandTraining
import WhoopStore

@MainActor
final class MuscleAnalyticsModel: ObservableObject {
    @Published private(set) var balance: MuscleBalanceResult?
    @Published private(set) var fatigue: MuscleFatigueResult?
    @Published private(set) var strength: MuscleStrengthResult?
    @Published private(set) var loading = false

    func load(history: ResolvedStrengthHistory, repo: Repository) async {
        loading = true
        let now = Int(Date().timeIntervalSince1970)
        let evidence = history.muscleMetricSets()
        let observations: [MuscleRecovery.Observation]
        if let store = await repo.storeHandle() {
            observations = ((try? await store.muscleRecoveryFeedback()) ?? []).compactMap { row in
                MuscleRecovery.Feeling(rawValue: row.feeling).map {
                    .init(group: row.muscleGroup, ts: row.ts, feeling: $0)
                }
            }
        } else {
            observations = []
        }

        let workouts = history.workouts
        let templates = history.templates
        let availableFrom = history.historyAvailableFrom
        let result = await Task.detached(priority: .userInitiated) { () -> Snapshot in
            let index = MuscleStimulus.SessionStimulusIndex(workouts: workouts, templates: templates)
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
                let group = MuscleAnalyticsModel.coarseGroup(for: muscle.id)
                tauByMuscle[muscle.id] = tauByGroup[group]
                    ?? MuscleRecovery.defaultTauSeconds(for: group)
                if fittedGroups.contains(group) { fittedMuscles.insert(muscle.id) }
            }
            return Snapshot(
                balance: MuscleBalanceMetric.calculate(
                    sets: evidence, now: now, historyAvailableFrom: availableFrom),
                fatigue: MuscleFatigueMetric.calculate(
                    sets: evidence, now: now, tauByMuscle: tauByMuscle,
                    personallyFittedMuscles: fittedMuscles),
                strength: MuscleStrengthMetric.calculate(sets: evidence))
        }.value
        balance = result.balance
        fatigue = result.fatigue
        strength = result.strength
        loading = false
    }

    private struct Snapshot: Sendable {
        let balance: MuscleBalanceResult
        let fatigue: MuscleFatigueResult
        let strength: MuscleStrengthResult
    }

    private nonisolated static func coarseGroup(for id: String) -> HevyMuscleGroup {
        switch id {
        case "chest", "upper_chest", "lower_chest": return .chest
        case "front_delts", "side_delts", "rear_delts", "rotator_cuff": return .shoulders
        case "triceps": return .triceps
        case "biceps": return .biceps
        case "forearms": return .forearms
        case "lats": return .lats
        case "upper_back", "rhomboids": return .upperBack
        case "traps", "upper_traps", "lower_traps": return .traps
        case "lower_back": return .lowerBack
        case "quadriceps", "inner_quadriceps", "outer_quadriceps": return .quadriceps
        case "hamstrings": return .hamstrings
        case "glutes": return .glutes
        case "adductors": return .adductors
        case "abductors", "hip_flexors": return .abductors
        case "calves", "tibialis": return .calves
        case "neck": return .neck
        default: return .abdominals
        }
    }
}
