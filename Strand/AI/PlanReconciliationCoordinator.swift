import Foundation
import WhoopStore

/// App-side: applies the matcher's result to the plan store and posts the notifications (`CoachNotifier`).
@MainActor
enum PlanReconciliationCoordinator {
    /// Rebuild the closed loop from the canonical, already cross-source-deduplicated workout feed.
    @discardableResult
    static func reconcile(repo: any CoachDataReading, store suppliedStore: CoachPlanStore? = nil,
                          now: Date = Date()) async -> [PlanReconciliationResolution] {
        let store = suppliedStore ?? CoachPlanStore.shared
        PlanGoalAttributionMigration.runIfNeeded(store: store, goals: CoachGoalStore.shared.goals)
        // `reconcileHrCap: 0` — matching keys on `(startTs, endTs, sport)` and never consults HR. `strain` is
        // carried into `completionEvidence`, which no view reads, and only for automatic matches. The
        // display-only HR reconcile would put one query per candidate workout on the launch path for
        // nothing. See `Repository.workoutRows(days:reconcileHrCap:)`.
        let workouts = await repo.workoutRows(days: 45, reconcileHrCap: 0)
        let result = PlanWorkoutMatcher.match(proposals: store.proposals, workouts: workouts, now: now)
        for match in result.automatic {
            let proposal = store.proposals.first { $0.id == match.proposalId }
            store.complete(match.proposalId,
                           evidence: match.workout.completionEvidence(method: .automatic,
                                                                        matchedAt: now))
            if let proposal {
                CoachNotifier.postAutomaticCompletion(proposal: proposal, workout: match.workout,
                                                       now: now)
            }
        }
        // Re-run after mutations so conflicts freed by an automatic match and every transient question
        // reflect the persisted state rather than the pre-mutation snapshot.
        let final = PlanWorkoutMatcher.match(proposals: store.proposals, workouts: workouts, now: now)
        store.setReconciliationResolutions(final.resolutions)
        CoachNotifier.syncPlanReconciliation(final.resolutions, proposals: store.proposals, now: now)
        return final.resolutions
    }
}
