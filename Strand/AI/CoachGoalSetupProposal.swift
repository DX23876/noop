import Foundation
import Combine

/// A coach-authored setup is deliberately inert until the person reviews it. It may contain one goal
/// plus several reusable actions, including edits of existing records, but none of those stores are
/// touched by creating this value.
struct CoachGoalSetupProposal: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case proposed, accepted, declined }
    enum Operation: String, Codable { case create, update }

    struct BaselineEvidence: Codable, Equatable {
        let value: Double
        let date: Date?
        let source: String
    }

    struct GoalDraft: Codable, Equatable {
        var operation: Operation
        var editingId: UUID?
        var goal: CoachGoal
        var baselineEvidence: BaselineEvidence?
    }

    struct RoutineDraft: Codable, Identifiable, Equatable {
        var operation: Operation
        var editingId: UUID?
        var action: GoalAction
        var id: UUID { action.id }
    }

    let id: UUID
    var goal: GoalDraft?
    var routines: [RoutineDraft]
    /// Weekly and monthly goals drafted alongside (goals plan §14). Optional so drafts stored before
    /// these existed still decode.
    var periodGoals: [PeriodGoal]?
    var rationale: String
    var status: Status
    let createdAt: Date
    var decidedAt: Date?

    init(id: UUID = UUID(), goal: GoalDraft?, routines: [RoutineDraft], periodGoals: [PeriodGoal] = [],
         rationale: String, status: Status = .proposed, createdAt: Date = Date(), decidedAt: Date? = nil) {
        self.id = id
        self.goal = goal
        self.routines = Array(routines.prefix(5))
        self.periodGoals = periodGoals.isEmpty ? nil : Array(periodGoals.prefix(CoachGoalSetupProposal.maxPeriodGoals))
        self.rationale = rationale
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }

    static let maxPeriodGoals = 3
    var draftedPeriodGoals: [PeriodGoal] { periodGoals ?? [] }
    var isEmpty: Bool { goal == nil && routines.isEmpty && draftedPeriodGoals.isEmpty }
}

@MainActor
final class CoachGoalSetupProposalStore: ObservableObject {
    static let shared = CoachGoalSetupProposalStore()
    static let storageKey = "coach.goalSetupProposals.v1"
    static let maxProposals = 20

    @Published private(set) var proposals: [CoachGoalSetupProposal] = [] { didSet { save() } }
    var pending: [CoachGoalSetupProposal] {
        proposals.filter { $0.status == .proposed }.sorted { $0.createdAt > $1.createdAt }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var isLoading = true

    init(defaults: UserDefaults = .standard,
         storageKey: String = "coach.goalSetupProposals.v1", loading: Bool = true) {
        self.defaults = defaults
        self.storageKey = storageKey
        if loading, let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CoachGoalSetupProposal].self, from: data) {
            proposals = decoded
        }
        isLoading = false
    }

    @discardableResult
    func propose(_ proposal: CoachGoalSetupProposal) -> Bool {
        guard !proposal.isEmpty else { return false }
        // This is the only entry point the model can reach. Ignore any supplied decision state so a
        // malformed/provider-authored payload can never pre-accept its own setup.
        var pending = proposal
        pending.status = .proposed
        pending.decidedAt = nil
        proposals.insert(pending, at: 0)
        if proposals.count > Self.maxProposals {
            proposals = Array(proposals.prefix(Self.maxProposals))
        }
        return true
    }

    func proposal(id: UUID) -> CoachGoalSetupProposal? { proposals.first { $0.id == id } }

    func decide(_ id: UUID, as status: CoachGoalSetupProposal.Status, now: Date = Date()) {
        guard status != .proposed,
              let index = proposals.firstIndex(where: { $0.id == id && $0.status == .proposed }) else { return }
        proposals[index].status = status
        proposals[index].decidedAt = now
    }

    private func save() {
        guard !isLoading, let data = try? JSONEncoder().encode(proposals) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// The single mutation boundary for a reviewed setup. All references and goal limits are checked before
/// either destination store is touched, so an outdated draft cannot leave behind half an application.
@MainActor
enum CoachGoalSetupApplier {
    struct Selection {
        var goal: CoachGoalSetupProposal.GoalDraft?
        var includeGoal: Bool
        var routines: [CoachGoalSetupProposal.RoutineDraft]
        var selectedRoutineIds: Set<UUID>
        var replacingGoalId: UUID?
        var acknowledgedRisk: CoachGoal.RiskAcknowledgement?
        var clearStaleAcknowledgement: Bool
        /// The drafted weekly and monthly goals, as possibly edited in the review, and which are chosen.
        var periodGoals: [PeriodGoal] = []
        var selectedPeriodGoalIds: Set<UUID> = []
    }

    enum ApplyError: LocalizedError, Equatable {
        case proposalUnavailable
        case goalUnavailable
        case routineUnavailable
        case goalLimit
        case missingGoalLink
        case unavailableGoalLink
        case periodGoalLimit
        case periodGoalDuplicate
        case linkedWeeklyGoalRequired

        var errorDescription: String? {
            switch self {
            case .proposalUnavailable: return "This draft is no longer waiting for review."
            case .goalUnavailable: return "The goal this draft wanted to update no longer exists."
            case .routineUnavailable: return "A routine this draft wanted to update no longer exists."
            case .goalLimit: return "This goal conflicts with your current active-goal limit."
            case .missingGoalLink: return "Every selected routine must support at least one goal."
            case .unavailableGoalLink: return "A selected routine refers to a goal that is no longer active."
            case .periodGoalLimit:
                return String(localized: "These weekly or monthly goals would go past your limit. End one first or raise the limit in goal settings.")
            case .periodGoalDuplicate:
                return String(localized: "You already track this over the same period. Change that goal instead.")
            case .linkedWeeklyGoalRequired:
                return String(localized: "This goal is measured by its weekly goal. Keep the weekly goal selected, or leave the goal out.")
            }
        }
    }

    static func apply(proposalId: UUID, selection: Selection,
                      proposalStore: CoachGoalSetupProposalStore,
                      goalStore: CoachGoalStore, actionStore: GoalActionStore,
                      periodStore: PeriodGoalStore = .shared,
                      today: String = Repository.localDayKey(Date())) -> ApplyError? {
        guard proposalStore.proposal(id: proposalId)?.status == .proposed else {
            return .proposalUnavailable
        }

        let includedGoalId: UUID?
        if selection.includeGoal {
            guard let draft = selection.goal else { return .goalUnavailable }
            if draft.operation == .update {
                guard let editingId = draft.editingId,
                      let existing = goalStore.goal(id: editingId),
                      existing.status == .active || existing.status == .paused else { return .goalUnavailable }
            }
            if let limit = goalStore.canAdd(kind: draft.goal.kind, replacing: draft.editingId) {
                switch limit {
                case .kindAlreadyActive(let existingId):
                    // Replace the existing goal, or keep both while the ceiling has room.
                    guard selection.replacingGoalId == existingId
                            || goalStore.hasRoom(replacing: draft.editingId) else { return .goalLimit }
                case .tooManyActive:
                    return .goalLimit
                }
            }
            includedGoalId = draft.goal.id
        } else {
            includedGoalId = nil
        }

        let activeIds = Set(goalStore.activeGoals.map(\.id))
        var preparedActions: [GoalAction] = []
        for routine in selection.routines where selection.selectedRoutineIds.contains(routine.id) {
            if routine.operation == .update {
                guard let editingId = routine.editingId,
                      actionStore.actions.contains(where: { $0.id == editingId }) else {
                    return .routineUnavailable
                }
            }
            var action = routine.action
            if !selection.includeGoal, let setupId = selection.goal?.goal.id {
                action.goalIds.removeAll { $0 == setupId }
            }
            guard !action.goalIds.isEmpty else { return .missingGoalLink }
            let allowedIds = includedGoalId.map { activeIds.union([$0]) } ?? activeIds
            guard Set(action.goalIds).isSubset(of: allowedIds) else { return .unavailableGoalLink }
            preparedActions.append(action)
        }

        // A weekly-rhythm catalog goal reads only its own weekly goal: without it there is nothing to judge.
        if selection.includeGoal, let weeklyId = selection.goal?.goal.measure?.weeklyGoalId,
           selection.periodGoals.contains(where: { $0.id == weeklyId }),
           !selection.selectedPeriodGoalIds.contains(weeklyId) {
            return .linkedWeeklyGoalRequired
        }

        // Weekly and monthly goals: checked one after another against the goals already open plus the
        // ones accepted before them in this same draft, so two drafts cannot both take the last slot.
        var preparedPeriodGoals: [PeriodGoal] = []
        let allowedParents = includedGoalId.map { activeIds.union([$0]) } ?? activeIds
        for draft in selection.periodGoals where selection.selectedPeriodGoalIds.contains(draft.id) {
            var goal = draft
            if let parent = goal.parentGoalId, !allowedParents.contains(parent) { goal.parentGoalId = nil }
            let sameSlot = preparedPeriodGoals.contains {
                $0.metric == goal.metric && $0.period == goal.period
                    && Set($0.sportFilter.map { $0.lowercased() }) == Set(goal.sportFilter.map { $0.lowercased() })
            }
            if sameSlot { return .periodGoalDuplicate }
            switch periodStore.canAdd(goal) {
            case .duplicate: return .periodGoalDuplicate
            case .limitReached: return .periodGoalLimit
            case nil: break
            }
            if periodStore.openGoals.count + preparedPeriodGoals.count >= GoalPrefs.periodLimit {
                return .periodGoalLimit
            }
            preparedPeriodGoals.append(goal)
        }

        if selection.includeGoal, let draft = selection.goal {
            goalStore.commit(draft.goal, editingId: draft.editingId,
                             replacing: selection.replacingGoalId,
                             acknowledgedRisk: selection.acknowledgedRisk,
                             clearStaleAck: selection.clearStaleAcknowledgement)
        }
        preparedActions.forEach(actionStore.upsert)
        for goal in preparedPeriodGoals { periodStore.commit(goal, today: today) }
        proposalStore.decide(proposalId, as: .accepted)
        return nil
    }
}
