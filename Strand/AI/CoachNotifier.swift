import Foundation

/// Bridges the coach's two structured "the coach decided something" outputs — a detected
/// `ProactiveSignal` and a proposed `PlanProposal` — into the bell (`UpdateStore`). Deliberately a plain
/// Swift enum, not a new `CoachTool`: `ProactiveSignal` detection is pure, deterministic Swift that runs
/// unconditionally in `AICoachEngine.runProactiveNudgeIfNeeded()`, before any model call — making it a
/// tool would require the model to choose to call it, which would break "the same detection also posts
/// a bell item" being purely additive to today's chat-nudge behaviour. `propose_plan` already has the
/// right call site (`AICoachEngine.proposePlanTool`); posting the bell wrapper there is a side effect of
/// an existing tool, not a second one.
@MainActor
enum CoachNotifier {

    /// Post a bell item for a detected proactive signal. Never `.actionable` — only a `PlanProposal`
    /// produces that category; a hint is never a decision.
    ///
    /// Gated the same way the chat nudge is: `level == .off` posts nothing, and at `.important` only
    /// `signal.important` signals post — a user who only wants to be interrupted for the big things
    /// shouldn't get a bell full of small-win hints their chat pane would never have shown them either.
    ///
    /// Same-day guard: `runProactiveNudgeIfNeeded()` only stamps its once-per-day guard AFTER a
    /// successful chat reply, so on a failed network call it deliberately retries the SAME detected
    /// signal later that day. `UpdateStore`'s own dedup window is only 30 minutes, so without this guard
    /// a retry hours later would append a duplicate row. Each signal category gets a synthetic
    /// `"proactive:<category>"` deep link; if an item with that link already exists for today, skip.
    static func postProactiveSignal(_ signal: ProactiveSignal, level: ProactiveLevel,
                                     store: UpdateStore = .shared, now: Date = Date()) {
        guard level != .off else { return }
        guard level == .normal || signal.important else { return }

        let deepLink = "proactive:\(signal.category.rawValue)"
        let today = Repository.logicalDayKey(now)
        let alreadyPostedToday = store.items.contains {
            $0.deepLink == deepLink && Repository.logicalDayKey($0.date) == today
        }
        guard !alreadyPostedToday else { return }

        let mapped = mapping(for: signal, now: now)
        store.post(UpdateItem(
            // All proactive hints reuse `.reading` — the closest existing "a data-derived note" icon;
            // nothing here is a release note or a dismissed card.
            kind: .reading,
            title: mapped.title,
            message: signal.seed,
            date: now,
            deepLink: deepLink,
            category: mapped.category,
            priority: mapped.priority,
            expiresAt: mapped.expiresAt,
            actionRequired: false,
            showOnToday: false
        ))
    }

    /// Post (or refresh) the actionable wrapper item for a freshly-proposed `PlanProposal`. Called right
    /// after `CoachPlanStore.shared.propose(_:)` succeeds. A re-proposal of the same (day, sport) collapses
    /// onto the SAME `PlanProposal.id` (`CoachPlanStore.propose`'s own dedup) — so this refreshes the
    /// existing bell row in place instead of appending a second one for the same proposal.
    static func postPlanProposal(_ proposal: PlanProposal, store: UpdateStore = .shared) {
        if let existing = store.items.first(where: {
            $0.category == .actionable && $0.planProposalId == proposal.id
        }) {
            store.refresh(existing.id, message: proposal.summary())
            return
        }
        store.post(UpdateItem(
            kind: .dismissedCard,
            title: String(localized: "Suggested session"),
            message: proposal.summary(),
            category: .actionable,
            priority: .normal,
            actionRequired: true,
            planProposalId: proposal.id,
            showOnToday: true
        ))
    }

    // MARK: - Mapping

    private struct Mapped {
        let category: UpdateItem.Category
        let priority: UpdateItem.Priority
        let expiresAt: Date?
        let title: String
    }

    /// `ProactiveSignal.Category` → bell category/priority/relevance-window. No case maps to
    /// `.actionable` — see the doc comment above.
    private static func mapping(for signal: ProactiveSignal, now: Date) -> Mapped {
        func days(_ n: Int) -> Date { now.addingTimeInterval(Double(n) * 24 * 3600) }
        switch signal.category {
        case .milestone:
            return Mapped(category: .informative,
                          priority: signal.important ? .high : .normal,
                          expiresAt: days(7),
                          title: String(localized: "Nice work"))
        case .setback:
            return Mapped(category: .informative, priority: .high, expiresAt: days(3),
                          title: String(localized: "A quick nudge"))
        case .bodyConcern:
            return Mapped(category: .informative, priority: .high, expiresAt: days(2),
                          title: String(localized: "Worth a look"))
        case .bodyPositive:
            return Mapped(category: .informative, priority: .normal, expiresAt: days(5),
                          title: String(localized: "Nice trend"))
        case .goalDeadline:
            let goalExpiry = signal.goalId.flatMap { CoachGoalStore.shared.goal(id: $0)?.targetDate }
            return Mapped(category: .statusReminder,
                          priority: signal.important ? .high : .normal,
                          expiresAt: goalExpiry ?? days(14),
                          title: String(localized: "Goal deadline"))
        }
    }
}
