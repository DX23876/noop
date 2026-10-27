import Foundation
import WhoopStore

/// Runs the existing goal stores over a private transaction image. Model cascades and GoalPrefs see
/// that same image only during synchronous work; no actor suspension exposes a temporary binding.
@MainActor
enum CoreGoalState {
    enum Failure: Error { case concurrentChange }

    struct Context {
        let preferences: GoalPreferenceImage
        let goals: CoachGoalStore
        let actions: GoalActionStore
        let periods: PeriodGoalStore
        let contributions: GoalContributionStore
        let corrections: GoalCountingCorrections
        let proposals: CoachGoalSetupProposalStore
    }

    static func read<T>(store: WhoopStore, _ body: (Context) throws -> T) async throws -> T {
        let data = try await store.goalPreferenceState()
        return try withImage(data, body)
    }

    /// A failed mutation or commit never publishes its image. Another caller can commit while this
    /// one awaits SQLite, so compare the persisted source image before replacing the whole state.
    static func change<T>(store: WhoopStore, _ body: (Context) throws -> T) async throws -> T {
        let previous = try await store.goalPreferenceState()
        let (result, replacement) = try withImage(previous) { context in
            let result = try body(context)
            let data = try context.preferences.serialized()
            return (result, data)
        }
        guard try await store.commitGoalPreferenceState(expected: previous, replacement: replacement) else {
            throw Failure.concurrentChange
        }
        return result
    }

    private static func withImage<T>(_ data: Data?, _ body: (Context) throws -> T) throws -> T {
        let image = try GoalPreferenceImage(serialized: data)
        let oldPreferences = GoalPreferences.standard
        let oldGoals = CoachGoalStore.shared
        let oldActions = GoalActionStore.shared
        let oldPeriods = PeriodGoalStore.shared
        let oldContributions = GoalContributionStore.shared
        let oldCorrections = GoalCountingCorrections.shared
        let oldProposals = CoachGoalSetupProposalStore.shared
        defer {
            GoalPreferences.standard = oldPreferences
            CoachGoalStore.shared = oldGoals
            GoalActionStore.shared = oldActions
            PeriodGoalStore.shared = oldPeriods
            GoalContributionStore.shared = oldContributions
            GoalCountingCorrections.shared = oldCorrections
            CoachGoalSetupProposalStore.shared = oldProposals
        }
        GoalPreferences.standard = image
        CoachGoalStore.shared = CoachGoalStore(defaults: image)
        GoalActionStore.shared = GoalActionStore(defaults: image)
        PeriodGoalStore.shared = PeriodGoalStore(defaults: image)
        GoalContributionStore.shared = GoalContributionStore(defaults: image)
        GoalCountingCorrections.shared = GoalCountingCorrections(defaults: image)
        CoachGoalSetupProposalStore.shared = CoachGoalSetupProposalStore(defaults: image)
        return try body(Context(preferences: image, goals: CoachGoalStore.shared, actions: GoalActionStore.shared,
            periods: PeriodGoalStore.shared, contributions: GoalContributionStore.shared,
            corrections: GoalCountingCorrections.shared, proposals: CoachGoalSetupProposalStore.shared))
    }
}
