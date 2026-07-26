import Foundation

// MARK: - Heute suggestion cards — real source (D-package 2)
//
// Heute's swipeable cards (feature-spec §3) used to show one hardcoded placeholder. The real source is
// the coach's own proposals: `propose_plan` writes `PlanProposal`s into `CoachPlanStore.shared`, and
// `store.pending` is the still-undecided set the other two Today screens surface via `MorningSuggestionCard`.
// This pure mapping turns those pending proposals into cards for Heute's card zone — display only; it
// never generates or mutates a proposal.
//
// Lives in `Strand/Data/` (not `StrandiOS/Redesign/`) so the mapping/store compile into the macOS target
// and are unit-testable there, exactly like `ActivityStatus` / `BaseCardStatement` / `VitalTileConfig`.

/// One ephemeral notification card (feature-spec §3: generic "title + text", not coupled to any specific
/// source — propose_plan / vitals-anomaly / future sources all produce the same shape).
struct NotificationCardItem: Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// Small overline tag, e.g. "Suggestion" / "Anomaly".
    var category: String
    /// The one-line body sentence.
    var text: String
}

enum HeuteSuggestionCards {
    /// The suggestion cards to show, in `store.pending` order. Empty when a training-suppressing activity
    /// status is set (Sick/Injured/On break) — that flag exists exactly to pause suggestions. Otherwise:
    /// the pending proposals for `dayKey` that the user hasn't locally dismissed, mapped to cards keyed by
    /// the proposal's own id (so a dismissal persists against the right proposal).
    static func cards(pending: [PlanProposal], dayKey: String,
                      status: ActivityStatus, dismissed: Set<String>) -> [NotificationCardItem] {
        guard !status.suppressesTrainingSuggestions else { return [] }
        return pending
            .filter { $0.day == dayKey && !dismissed.contains($0.id.uuidString) }
            .map { p in
                NotificationCardItem(id: p.id.uuidString,
                                     category: String(localized: "Suggestion"),
                                     text: text(for: p))
            }
    }

    /// One honest line: the coach's rationale when it wrote one, else a plain "intent · sport". `sport` is
    /// free text (the user's own vocabulary), so it isn't localized; the intent label is (see `intentLabel`).
    static func text(for p: PlanProposal) -> String {
        let rationale = p.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rationale.isEmpty { return "\(p.sport) — \(rationale)" }
        return "\(intentLabel(p.intent)) · \(p.sport)"
    }

    /// Localized intent label. `PlanProposal.Intent.label` is a raw English string (used in the coach's
    /// own English-only tool plumbing); a user-facing Heute card must be translated, so it's mapped here.
    static func intentLabel(_ intent: PlanProposal.Intent) -> String {
        switch intent {
        case .rest:     return String(localized: "Rest", comment: "PlanProposal intent")
        case .easy:     return String(localized: "Easy", comment: "PlanProposal intent")
        case .moderate: return String(localized: "Moderate", comment: "PlanProposal intent")
        case .hard:     return String(localized: "Hard", comment: "PlanProposal intent")
        case .mobility: return String(localized: "Mobility", comment: "PlanProposal intent")
        }
    }
}

/// UserDefaults-backed set of locally-dismissed proposal ids. A swipe on a Heute card hides it for good
/// WITHOUT touching the proposal's status — a casual swipe must not count as a formal `declined` (that
/// would feed `CoachPlanStore.declineStreak` / the filter-bubble floor). The formal decision lives in the
/// coach plan (tap → `CoachPlanView`). Injectable `UserDefaults` for test isolation.
enum DismissedSuggestionsStore {
    static let key = "today.dismissedSuggestions"

    /// Loads the dismissed ids, PRUNED to the ids still worth remembering (`keepingOnly`) so the set can't
    /// grow without bound as proposals get decided or age out. Writes the pruned set back when it shrank.
    static func load(from d: UserDefaults = .standard, keepingOnly liveIDs: Set<String> = []) -> Set<String> {
        let stored = Set(d.stringArray(forKey: key) ?? [])
        guard !liveIDs.isEmpty else { return stored }
        let pruned = stored.intersection(liveIDs)
        if pruned != stored { save(pruned, to: d) }
        return pruned
    }

    static func save(_ ids: Set<String>, to d: UserDefaults = .standard) {
        d.set(Array(ids), forKey: key)
    }
}
