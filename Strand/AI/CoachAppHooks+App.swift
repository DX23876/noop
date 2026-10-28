import Foundation

/// The app's hooks: the shared goal tracking store, the stored coach identity, and `CoachNotifier`.
struct AppCoachHooks: CoachAppHooks {
    var goalTracking: GoalTrackingModel { GoalTrackingStore.shared }
    var identityPreamble: String { CoachIdentityStore.shared.identity.identityPreamble }
    func planProposed(_ proposal: PlanProposal) { CoachNotifier.postPlanProposal(proposal) }
    func proactiveSignal(_ signal: ProactiveSignal, level: ProactiveLevel) {
        CoachNotifier.postProactiveSignal(signal, level: level)
    }
}

@MainActor
func coachAppHooks() -> any CoachAppHooks { AppCoachHooks() }
