import Foundation
import WhoopStore

// MARK: - A routine the coach has DRAFTED, and nobody has sent anywhere
//
// The coach can design a training routine. It cannot put one in the user's Hevy account. This type is
// the gap between those two sentences, and it is the same gap `CoachGoalSetupProposal` already holds
// for goals: the model produces a draft, the draft sits in an inbox, a review screen shows it in full,
// and only an explicit "Send to Hevy" performs a network write.
//
// WHY THAT MATTERS MORE HERE than for a local goal: this writes to a THIRD-PARTY ACCOUNT the user owns.
// A wrong local goal is a row to delete. A wrong routine pushed to Hevy is something they find in the
// gym, and — because Hevy's `PUT` is a full replace, with no partial update available — an edit that
// drops half a plan they spent months on. That is why `previousExercises` is carried: so the review
// screen shows what WOULD be lost before it is, rather than after.
//
// ## A boundary this deliberately crosses
//
// `CoachPlanStore.PlanProposal` documents an explicit decision: "Deliberately coarse — NOOP prescribes
// intent and rough load, NOT sets and reps, because intent is what its data can actually speak to."
// That was right when the only evidence was heart rate. With Hevy synced there is per-set evidence —
// loads, reps, RPE, an e1RM trend per movement — so sets and reps are now something the data supports.
// The two types stay separate rather than one being loosened: `PlanProposal` still describes a day's
// intent; this describes a routine's contents.

/// One set in a drafted routine. Mirrors Hevy's `PostRoutinesRequestSet`, minus the fields NOOP has no
/// business inventing (distance, duration and the custom metric belong to movements this draft path
/// does not prescribe).
struct HevyRoutineDraftSet: Codable, Equatable {
    var type: HevySetType
    var weightKg: Double?
    var reps: Int?
    /// A prescribed rep RANGE ("8–12"), which is how strength programmes are actually written. Hevy
    /// stores it natively, so a range survives as a range rather than collapsing to its midpoint.
    var repRangeStart: Int?
    var repRangeEnd: Int?

    init(type: HevySetType = .normal, weightKg: Double? = nil, reps: Int? = nil,
         repRangeStart: Int? = nil, repRangeEnd: Int? = nil) {
        self.type = type
        self.weightKg = weightKg
        self.reps = reps
        self.repRangeStart = repRangeStart
        self.repRangeEnd = repRangeEnd
    }

    /// How the review screen states this set. The point is that a reader can check it against what they
    /// know they lift, so it says the numbers plainly and never rounds them away.
    var summary: String {
        var parts: [String] = []
        if let start = repRangeStart, let end = repRangeEnd {
            parts.append("\(start)–\(end)")
        } else if let reps {
            parts.append("\(reps)")
        }
        if let weightKg, weightKg > 0 {
            parts.append(String(format: "%.1f kg", weightKg))
        }
        let core = parts.isEmpty ? String(localized: "no target") : parts.joined(separator: " × ")
        return type == .normal ? core : "\(core) (\(type.rawValue))"
    }
}

/// One exercise in a drafted routine.
struct HevyRoutineDraftExercise: Codable, Equatable, Identifiable {
    /// Hevy's own template id. Validated against the LOCAL catalogue before a draft is ever created —
    /// see `proposeHevyRoutineTool`. Without that check the model invents plausible-looking ids and
    /// the write fails at the API, or worse, lands on a different movement.
    var templateId: String
    /// The catalogue title at drafting time, so the review screen can name the movement even if the
    /// catalogue is re-synced in between.
    var title: String
    var supersetId: Int?
    var restSeconds: Int?
    var notes: String?
    var sets: [HevyRoutineDraftSet]

    var id: String { "\(templateId)-\(title)" }

    init(templateId: String, title: String, supersetId: Int? = nil, restSeconds: Int? = nil,
         notes: String? = nil, sets: [HevyRoutineDraftSet]) {
        self.templateId = templateId
        self.title = title
        self.supersetId = supersetId
        self.restSeconds = restSeconds
        self.notes = notes
        self.sets = sets
    }
}

/// A drafted routine, waiting for the user.
struct HevyRoutineProposal: Codable, Identifiable, Equatable {

    enum Operation: String, Codable { case create, update }

    enum Status: String, Codable {
        /// Where every draft starts and stays until the user acts.
        case proposed
        /// Sent to Hevy successfully.
        case sent
        case declined
        /// The user said yes and the write failed. Kept distinct from `.proposed` so a retry is
        /// offered rather than the draft silently reappearing as if nothing had been attempted.
        case failed
    }

    let id: UUID
    var operation: Operation
    /// For `.update`: the Hevy routine being changed.
    var routineId: String?
    var title: String
    var notes: String?
    var folderId: Int?
    var exercises: [HevyRoutineDraftExercise]
    /// Why the coach drafted this, in its own words. Shown above the sets, because a plan without a
    /// reason is a plan nobody can disagree with.
    var rationale: String
    /// For `.update`: the routine's contents BEFORE the change, so the review screen can show a real
    /// before/after and so an accepted change is undoable. Hevy's `PUT` is a full replace, and without
    /// a snapshot the previous version is gone the instant the write succeeds.
    var previousExercises: [HevyRoutineDraftExercise]?
    /// The verbatim server document for `.update`.
    ///
    /// NOT used to merge into the write: `PUT /v1/routines/{id}` is a full replace, and sending fields
    /// the documented request body does not list would be a live experiment on someone's training log.
    /// It is kept so the review screen can show a real before/after, and so a sent change can be
    /// restored — which is the actual protection against a draft that would drop half a routine.
    var previousRawJSON: String?
    /// Deterministic warnings from `StrengthPlanGate`, computed BEFORE the model saw the draft and
    /// stored with it, so the review screen shows the same verdict the gate reached rather than
    /// re-deriving one that could differ.
    var warnings: [String]
    var status: Status
    let createdAt: Date
    var decidedAt: Date?
    /// The failure text of the last send attempt, for the retry affordance.
    var lastError: String?

    init(id: UUID = UUID(), operation: Operation, routineId: String? = nil, title: String,
         notes: String? = nil, folderId: Int? = nil, exercises: [HevyRoutineDraftExercise],
         rationale: String, previousExercises: [HevyRoutineDraftExercise]? = nil,
         previousRawJSON: String? = nil, warnings: [String] = [],
         status: Status = .proposed, createdAt: Date = Date(), decidedAt: Date? = nil,
         lastError: String? = nil) {
        self.id = id
        self.operation = operation
        self.routineId = routineId
        self.title = title
        self.notes = notes
        self.folderId = folderId
        // Bounded like `CoachGoalSetupProposal` bounds its routines: a draft with forty exercises is a
        // runaway, not a plan, and the review screen has to stay readable.
        self.exercises = Array(exercises.prefix(20))
        self.rationale = rationale
        self.previousExercises = previousExercises
        self.previousRawJSON = previousRawJSON
        self.warnings = warnings
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.lastError = lastError
    }

    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    /// Working sets only — a warmup is not what a routine's volume is judged on.
    var totalWorkingSets: Int {
        exercises.reduce(0) { $0 + $1.sets.filter { $0.type.countsAsWork }.count }
    }
}

/// The inbox of drafted routines.
///
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
