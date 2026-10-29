import Foundation
import WhoopStore
#if canImport(Combine)
import Combine
#endif

/// UserDefaults-backed, `@MainActor`, `pending` filtered to `.proposed` — the same shape and the same
/// bounds as `CoachGoalSetupProposalStore`, so the two review flows behave identically.
@MainActor
final class HevyRoutineProposalStore: ObservableObject {
    static let shared = HevyRoutineProposalStore()
    static let storageKey = "hevy.routineProposals.v1"
    static let maxProposals = 20

    @Published private(set) var proposals: [HevyRoutineProposal] = [] { didSet { save() } }

    var pending: [HevyRoutineProposal] {
        proposals.filter { $0.status == .proposed || $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var isLoading = true

    init(defaults: UserDefaults = .standard,
         storageKey: String = HevyRoutineProposalStore.storageKey, loading: Bool = true) {
        self.defaults = defaults
        self.storageKey = storageKey
        if loading, let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([HevyRoutineProposal].self, from: data) {
            proposals = decoded
        }
        isLoading = false
    }

    /// The ONLY entry point the model can reach. Any supplied decision state is discarded, so a
    /// malformed or provider-authored payload can never pre-accept its own draft — the same guard
    /// `CoachGoalSetupProposalStore.propose` applies, and for the same reason.
    @discardableResult
    func propose(_ proposal: HevyRoutineProposal) -> Bool {
        guard !proposal.exercises.isEmpty else { return false }
        var pending = proposal
        pending.status = .proposed
        pending.decidedAt = nil
        pending.lastError = nil
        proposals.insert(pending, at: 0)
        if proposals.count > Self.maxProposals {
            proposals = Array(proposals.prefix(Self.maxProposals))
        }
        return true
    }

    func proposal(id: UUID) -> HevyRoutineProposal? { proposals.first { $0.id == id } }

    func decide(_ id: UUID, as status: HevyRoutineProposal.Status,
                error: String? = nil, now: Date = Date()) {
        guard status != .proposed,
              let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].status = status
        proposals[index].decidedAt = now
        proposals[index].lastError = error
    }

    private func save() {
        guard !isLoading, let data = try? JSONEncoder().encode(proposals) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
