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
        let observations: [MuscleRecovery.Observation]
        if let store = await repo.storeHandle() {
            observations = MuscleAnalyticsSnapshot.observations((try? await store.muscleRecoveryFeedback()) ?? [])
        } else {
            observations = []
        }
        let result = await Task.detached(priority: .userInitiated) {
            MuscleAnalyticsSnapshot.compute(history: history, observations: observations, now: now)
        }.value
        balance = result.balance
        fatigue = result.fatigue
        strength = result.strength
        loading = false
    }
}
