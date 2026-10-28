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
        CoreGoalHost.adopt(replacement, from: store)
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

/// The goal stores the shared coach reads between transactions. The coach engine, its goal tools and the screens
/// built on them (`CoachGoalStore.shared` and its siblings) read and write the process-wide stores, which on Android
/// start as an empty image that is never saved. The host installs the persisted image there before a coach
/// operation, writes back what the operation changed, and takes over every image `CoreGoalState.change` commits, so
/// the coach sees the wearer's goals and what it drafts survives a restart.
@MainActor
enum CoreGoalHost {
    private static var store: ObjectIdentifier?
    private static var source: Data?
    private static var installed = false

    /// Installs the stored image, unless the host already holds exactly that image for this store.
    static func load(_ store: WhoopStore) async {
        let data = try? await store.goalPreferenceState()
        if installed, self.store == ObjectIdentifier(store), data == source { return }
        install(data)
        self.store = ObjectIdentifier(store)
    }

    /// Saves what changed in the host stores since the last load. A concurrent commit wins: the host then takes
    /// the stored image over rather than overwrite newer input.
    static func persist(_ store: WhoopStore) async {
        guard installed, self.store == ObjectIdentifier(store),
              let image = GoalPreferences.standard as? GoalPreferenceImage,
              let data = try? image.serialized(), data != source else { return }
        if (try? await store.commitGoalPreferenceState(expected: source, replacement: data)) == true {
            source = data
        } else {
            install(try? await store.goalPreferenceState())
        }
    }

    /// A transaction committed `data` to `store`; the host follows it when it holds that store's goals.
    static func adopt(_ data: Data, from store: WhoopStore) {
        if installed, self.store == ObjectIdentifier(store) { install(data) }
    }

    /// Runs `body` with the persisted goals installed and saves what it changed.
    static func with<T>(_ store: WhoopStore, _ body: @MainActor () async -> T) async -> T {
        await load(store)
        let result = await body()
        await persist(store)
        return result
    }

    private static func install(_ data: Data?) {
        let image = (try? GoalPreferenceImage(serialized: data)) ?? GoalPreferenceImage()
        GoalPreferences.standard = image
        CoachGoalStore.shared = CoachGoalStore(defaults: image)
        GoalActionStore.shared = GoalActionStore(defaults: image)
        PeriodGoalStore.shared = PeriodGoalStore(defaults: image)
        GoalContributionStore.shared = GoalContributionStore(defaults: image)
        GoalCountingCorrections.shared = GoalCountingCorrections(defaults: image)
        CoachGoalSetupProposalStore.shared = CoachGoalSetupProposalStore(defaults: image)
        source = data
        installed = true
    }
}
