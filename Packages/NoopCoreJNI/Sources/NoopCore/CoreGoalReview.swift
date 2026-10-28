import Foundation
import StrandCore

/// The review of a goal and routine draft the coach left (`CoachGoalSetupReviewView` with its
/// `CoachRoutineDraftEditor`). The review's working copy lives here between calls, as the iOS view keeps it in
/// `@State`: Android sends each change and draws what comes back, and applying goes through the shared
/// `CoachGoalSetupApplier` with iOS's gate order (a missing routine or goal, a kind or measure already active,
/// the goal ceiling, then the pace reason).
@MainActor
enum CoreGoalReview {
    private struct Session {
        var proposalId: UUID
        var goal: CoachGoalSetupProposal.GoalDraft?
        var routines: [CoachGoalSetupProposal.RoutineDraft]
        var selectedRoutines: Set<UUID>
        var periods: [PeriodGoal]
        var selectedPeriods: Set<UUID>
        var includeGoal: Bool
        var rationale: String
        var replaceCandidate: UUID?
    }
    private static var session: Session?

    struct Choice: Encodable { var id: String, label: String, on: Bool }
    struct Goal: Encodable {
        var include: Bool, includeLabel: String
        var templateTitle: String?, kind: String, kinds: [Choice]
        var title: String, showBaseline: Bool, baselineLabel: String, baseline: String
        var showTarget: Bool, targetLabel: String, target: String, evidence: String?
        var dateAllowed: Bool, hasDate: Bool, date: Double
        var tags: [Choice], safetyWarning: String?, volumeWarning: String?
    }
    /// What the routine editor starts from (`CoachRoutineDraftEditor.init`).
    struct RoutineEdit: Encodable {
        var title: String, kind: String, steps: Int, sports: String, minutes: Int, hasMinimum: Bool
        var daily: Bool, weekdays: [Int], goalIds: [String]
    }
    struct Routine: Encodable {
        var id: String, title: String, detail: String, linked: String, selected: Bool, unavailable: Bool, edit: RoutineEdit
    }
    struct Period: Encodable {
        var id: String, title: String, sports: String?, serves: String?, amount: String, note: String?, selected: Bool
    }
    struct State: Encodable {
        var open: Bool, title: String, rationale: String
        var goal: Goal?, routines: [Routine], periods: [Period], goals: [Choice]
        var canApply: Bool
        /// After `apply`: what to ask next (`replace`, `reason`), an error, or that it was applied.
        var ask: String?, keepBoth: Bool, error: String?, applied: Bool
        var labels: [String: String]
    }

    static func run(_ op: String, _ args: [String: Any]) -> State {
        let weightKg = (args["weightKg"] as? NSNumber)?.doubleValue ?? 0
        var ask: String?, error: String?, applied = false
        func uuid(_ key: String) -> UUID? { (args[key] as? String).flatMap(UUID.init(uuidString:)) }
        switch op {
        case "coach.drafts.goal.open":
            session = nil
            if let id = uuid("id"), let p = CoachGoalSetupProposalStore.shared.proposal(id: id), p.status == .proposed {
                let periods = p.draftedPeriodGoals
                session = Session(proposalId: id, goal: p.goal, routines: p.routines, selectedRoutines: Set(p.routines.map(\.id)),
                                  periods: periods,
                                  selectedPeriods: Set(periods.filter { PeriodGoalStore.shared.canAdd($0) == nil }.map(\.id)),
                                  includeGoal: p.goal != nil, rationale: p.rationale)
            } else {
                error = "This draft is no longer waiting for review.".localizedCatalogValue
            }
        case "coach.drafts.goal.set": edit(args)
        case "coach.drafts.goal.routine": saveRoutine(args)
        case "coach.drafts.goal.decline":
            if let s = session { CoachGoalSetupProposalStore.shared.decide(s.proposalId, as: .declined) }
            session = nil
        case "coach.drafts.goal.apply":
            (ask, error, applied) = apply(stage: args["stage"] as? String ?? "start", reason: args["reason"] as? String ?? "",
                                          weightKg: weightKg)
        default: break
        }
        return state(weightKg: weightKg, ask: ask, error: error, applied: applied)
    }

    // MARK: - Editing

    private static func edit(_ args: [String: Any]) {
        guard var s = session else { return }
        if let on = args["includeGoal"] as? Bool {
            s.includeGoal = on
            if !on { for r in s.routines where onlySupportsSetupGoal(r, s) { s.selectedRoutines.remove(r.id) } }
        }
        if let raw = args["kind"] as? String, let kind = CoachGoal.Kind(rawValue: raw) {
            s.goal?.goal.kind = kind; s.goal?.baselineEvidence = nil
        }
        if let title = args["title"] as? String { s.goal?.goal.title = title }
        if let text = args["baseline"] as? String { s.goal?.goal.baseline = Double(text.replacingOccurrences(of: ",", with: ".")) }
        if let text = args["target"] as? String { s.goal?.goal.target = Double(text.replacingOccurrences(of: ",", with: ".")) }
        if let on = args["hasDate"] as? Bool {
            let current = s.goal?.goal.targetDate
            s.goal?.goal.targetDate = on ? (current ?? Date().addingTimeInterval(60 * 86_400)) : nil
        }
        if let secs = (args["date"] as? NSNumber)?.doubleValue { s.goal?.goal.targetDate = Date(timeIntervalSince1970: secs) }
        if let raw = args["tag"] as? String, let tag = CoachGoal.MotivationTag(rawValue: raw), var tags = s.goal?.goal.motivationTags {
            if let i = tags.firstIndex(of: tag) { tags.remove(at: i) } else { tags.append(tag) }
            s.goal?.goal.motivationTags = CoachGoal.MotivationTag.allCases.filter { tags.contains($0) }
        }
        if let id = (args["routine"] as? String).flatMap(UUID.init(uuidString:)),
           let r = s.routines.first(where: { $0.id == id }), !(!s.includeGoal && onlySupportsSetupGoal(r, s)) {
            if s.selectedRoutines.contains(id) { s.selectedRoutines.remove(id) } else { s.selectedRoutines.insert(id) }
        }
        if let id = (args["period"] as? String).flatMap(UUID.init(uuidString:)) {
            if s.selectedPeriods.contains(id) { s.selectedPeriods.remove(id) } else { s.selectedPeriods.insert(id) }
        }
        if let id = (args["periodStep"] as? String).flatMap(UUID.init(uuidString:)), let delta = args["delta"] as? Int,
           let i = s.periods.firstIndex(where: { $0.id == id }) {
            let g = s.periods[i]
            let range = g.metric.range(for: g.period)
            s.periods[i].target = min(max(g.target + Double(delta) * g.metric.step(for: g.period), range.lowerBound), range.upperBound)
        }
        session = s
    }

    /// `CoachRoutineDraftEditor.save`: a journal-linked routine edited as manual keeps its journal link, a sleep or
    /// energy routine keeps what it measures.
    private static func saveRoutine(_ args: [String: Any]) {
        guard var s = session, let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)),
              let i = s.routines.firstIndex(where: { $0.id == id }) else { return }
        var changed = s.routines[i]
        let old = changed.action.requirement
        changed.action.title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch args["kind"] as? String {
        case "steps": changed.action.requirement = .steps(minimum: args["steps"] as? Int ?? 10_000)
        case "workout":
            changed.action.requirement = .workout(
                sports: (args["sports"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                minimumMinutes: args["hasMinimum"] as? Bool == true ? args["minutes"] as? Int ?? 20 : nil)
        case "sleep", "calories": changed.action.requirement = old
        default:
            if case .journal = old { changed.action.requirement = old } else { changed.action.requirement = .manual }
        }
        changed.action.schedule = args["daily"] as? Bool == true ? .daily : .weekdays((args["weekdays"] as? [Int] ?? []).sorted())
        let picked = Set((args["goalIds"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        changed.action.goalIds = availableGoals(s).map(\.id).filter { picked.contains($0) }
        s.routines[i] = changed
        session = s
    }

    // MARK: - Applying (`attemptApply`, `proceedPastLimits`, `applySelection`)

    private static func apply(stage: String, reason: String, weightKg: Double) -> (String?, String?, Bool) {
        guard var s = session else { return (nil, "This draft is no longer waiting for review.".localizedCatalogValue, false) }
        let goals = CoachGoalStore.shared
        let limitText = String(format: "You already have %lld active goals. Close or set one aside first.".localizedCatalogValue,
                               CoachGoalStore.maxActiveGoals)
        let safety = s.goal.map { GoalSafetyGate.assess(goal: $0.goal, bodyWeightKg: weightKg) }
        func proceed() -> (String?, String?, Bool) {
            let existingAck = s.goal?.editingId.flatMap { goals.goal(id: $0)?.acknowledgedRisk }
            if s.includeGoal, safety?.requiresReason == true, existingAck == nil { return ("reason", nil, false) }
            return finish(acknowledging: false)
        }
        func finish(acknowledging: Bool) -> (String?, String?, Bool) {
            let ack = acknowledging
                ? CoachGoalRisk.acknowledgement(verdict: safety?.verdict.rawValue ?? "veryAggressive", reason: reason) : nil
            let clear = !acknowledging && (safety?.verdict == .ok || safety?.verdict == .notApplicable)
            let selection = CoachGoalSetupApplier.Selection(
                goal: s.goal, includeGoal: s.includeGoal, routines: s.routines, selectedRoutineIds: s.selectedRoutines,
                replacingGoalId: s.replaceCandidate, acknowledgedRisk: ack, clearStaleAcknowledgement: clear,
                periodGoals: s.periods, selectedPeriodGoalIds: s.selectedPeriods)
            if let failure = CoachGoalSetupApplier.apply(
                proposalId: s.proposalId, selection: selection, proposalStore: .shared,
                goalStore: goals, actionStore: GoalActionStore.shared) {
                return (nil, failure.localizedDescription, false)
            }
            session = nil
            return (nil, nil, true)
        }
        switch stage {
        case "replace": return proceed()
        case "keep": s.replaceCandidate = nil; session = s; return proceed()
        case "reason": return finish(acknowledging: true)
        default: break
        }
        for r in s.routines where s.selectedRoutines.contains(r.id) {
            if r.operation == .update,
               r.editingId == nil || !GoalActionStore.shared.actions.contains(where: { $0.id == r.editingId }) {
                return (nil, "A routine this draft wanted to update no longer exists.".localizedCatalogValue, false)
            }
            if effectiveGoalIds(r, s).isEmpty {
                return (nil, "Every selected routine must support at least one goal.".localizedCatalogValue, false)
            }
        }
        guard s.includeGoal, let draft = s.goal else { return finish(acknowledging: false) }
        if let editingId = draft.editingId, goals.goal(id: editingId) == nil {
            return (nil, "The goal this draft wanted to update no longer exists.".localizedCatalogValue, false)
        }
        if draft.goal.templateId != nil, draft.operation == .create {
            let weekly = GoalCatalog.template(for: draft.goal)?.id.weeklyMetric
            if let same = goals.activeGoal(measuringLike: draft.goal, weeklyMetric: weekly) {
                s.replaceCandidate = same.id; session = s; return ("replace", nil, false)
            }
            if !goals.hasRoom() { return (nil, limitText, false) }
            return proceed()
        }
        switch goals.canAdd(kind: draft.goal.kind, replacing: draft.editingId) {
        case .kindAlreadyActive(let id)?: s.replaceCandidate = id; session = s; return ("replace", nil, false)
        case .tooManyActive?: return (nil, limitText, false)
        case nil: return proceed()
        }
    }

    // MARK: - Reading

    private static func onlySupportsSetupGoal(_ r: CoachGoalSetupProposal.RoutineDraft, _ s: Session) -> Bool {
        guard let id = s.goal?.goal.id else { return false }
        return !r.action.goalIds.isEmpty && r.action.goalIds.allSatisfy { $0 == id }
    }

    private static func effectiveGoalIds(_ r: CoachGoalSetupProposal.RoutineDraft, _ s: Session) -> [UUID] {
        guard !s.includeGoal, let setupId = s.goal?.goal.id else { return r.action.goalIds }
        return r.action.goalIds.filter { $0 != setupId }
    }

    private static func availableGoals(_ s: Session) -> [CoachGoal] {
        var values = CoachGoalStore.shared.activeGoals
        if let setup = s.goal?.goal, !values.contains(where: { $0.id == setup.id }) { values.insert(setup, at: 0) }
        return values
    }

    private static func name(_ g: CoachGoal) -> String { g.title.isEmpty ? g.kind.label.localizedCatalogValue : g.title }

    private static func state(weightKg: Double, ask: String?, error: String?, applied: Bool) -> State {
        guard let s = session else {
            return State(open: false, title: "", rationale: "", goal: nil, routines: [], periods: [], goals: [], canApply: false,
                         ask: ask, keepBoth: false, error: error, applied: applied, labels: labels)
        }
        let store = CoachGoalStore.shared
        let available = availableGoals(s)
        var goal: Goal?
        if let d = s.goal {
            let g = d.goal
            let template = GoalCatalog.template(for: g)
            let evidence = d.baselineEvidence.map {
                String(format: "Local baseline: %@ · %@".localizedCatalogValue, String(format: "%g", $0.value), $0.source)
            }
            let quantified = template != nil || g.kind.isQuantified
            goal = Goal(
                include: s.includeGoal,
                includeLabel: (d.operation == .update ? "Apply goal changes" : "Create this goal").localizedCatalogValue,
                templateTitle: template?.title.localizedCatalogValue, kind: g.kind.rawValue,
                kinds: CoachGoal.Kind.templateFreeCases.map { Choice(id: $0.rawValue, label: $0.label.localizedCatalogValue, on: $0 == g.kind) },
                title: g.title,
                showBaseline: template.map { $0.shape == .target } ?? g.kind.isQuantified,
                baselineLabel: "Starting value".localizedCatalogValue, baseline: g.baseline.map { String(format: "%g", $0) } ?? "",
                showTarget: quantified,
                targetLabel: (template?.shape == .consistency ? "Per week" : "Target").localizedCatalogValue,
                target: g.target.map { String(format: "%g", $0) } ?? "", evidence: quantified ? evidence : nil,
                dateAllowed: template.map { ![GoalShape.average, .maintain, .consistency].contains($0.shape) } ?? true,
                hasDate: g.targetDate != nil, date: (g.targetDate ?? Date()).timeIntervalSince1970,
                tags: CoachGoal.MotivationTag.allCases.map { Choice(id: $0.rawValue, label: $0.label.localizedCatalogValue,
                                                                    on: g.motivationTags.contains($0)) },
                safetyWarning: GoalSafetyGate.assess(goal: g, bodyWeightKg: weightKg).warning,
                volumeWarning: GoalVolumeGate.assess(draft: g, against: store.activeGoals, excludingId: d.editingId).warning)
        }
        let routines = s.routines.map { r -> Routine in
            var kind = "manual", steps = 10_000, sports = "Walking", minutes = 20, hasMinimum = true
            switch r.action.requirement {
            case .steps(let v): kind = "steps"; steps = v
            case .workout(let v, let m): kind = "workout"; sports = v.joined(separator: ", "); minutes = m ?? 20; hasMinimum = m != nil
            case .sleep: kind = "sleep"
            case .activeCalories: kind = "calories"
            case .manual, .journal: break
            }
            var daily = true, weekdays = Array(1...7)
            if case .weekdays(let values) = r.action.schedule { daily = false; weekdays = values }
            return Routine(
                id: r.id.uuidString, title: r.action.title, detail: r.action.requirement.displayLabel,
                linked: r.action.goalIds.compactMap { id in available.first { $0.id == id }.map(name) }.joined(separator: " · "),
                selected: s.selectedRoutines.contains(r.id), unavailable: !s.includeGoal && onlySupportsSetupGoal(r, s),
                edit: RoutineEdit(title: r.action.title, kind: kind, steps: steps, sports: sports, minutes: minutes,
                                  hasMinimum: hasMinimum, daily: daily, weekdays: weekdays, goalIds: r.action.goalIds.map(\.uuidString)))
        }
        let today = StoreReader.localDayKey(Date())
        let periods = s.periods.map { p -> Period in
            var note: String?
            if case .duplicate = PeriodGoalStore.shared.canAdd(p) {
                note = "You already track this over the same period. Change that goal instead.".localizedCatalogValue
            } else {
                note = GoalConflicts.notes(adding: p, actions: GoalActionStore.shared.actions, period: PeriodGoalStore.shared.goals,
                                           longTerm: store.goals, today: today).first
            }
            var serves: String?
            if let parent = p.parentGoalId {
                let parentName = parent == s.goal?.goal.id ? (s.includeGoal ? s.goal?.goal.title : nil) : store.goal(id: parent)?.title
                serves = parentName.map { String(format: "Serves %@".localizedCatalogValue, $0) }
            }
            return Period(id: p.id.uuidString, title: GoalFormat.title(p), sports: p.sportFilter.isEmpty ? nil : GoalFormat.sports(p),
                          serves: serves, amount: GoalFormat.amount(p.target, p.metric), note: note,
                          selected: s.selectedPeriods.contains(p.id))
        }
        return State(
            open: true,
            title: (s.periods.isEmpty ? "Review goal & routines" : "Review coach draft").localizedCatalogValue,
            rationale: s.rationale, goal: goal, routines: routines, periods: periods,
            goals: available.map { Choice(id: $0.id.uuidString, label: name($0), on: false) },
            canApply: (s.includeGoal && s.goal != nil) || !s.selectedRoutines.isEmpty || !s.selectedPeriods.isEmpty,
            ask: ask, keepBoth: store.hasRoom(replacing: s.goal?.editingId), error: error, applied: applied, labels: labels)
    }

    static var labels: [String: String] {
        [
            "later": "Later", "apply": "Apply selection", "reasoning": "Coach's reasoning", "goal": "Goal", "type": "Type",
            "goalTitle": "Goal title", "targetDate": "Target date", "date": "Date", "why": "Why it matters",
            "routines": "Routines", "edit": "Edit", "unavailable": "Select the setup goal or link another active goal.",
            "periods": "Weekly and monthly goals",
            "inactive": "Nothing here is active until you confirm. Goal outcomes remain separate from routine completion.",
            "decline": "Decline draft",
            "replaceTitle": "Replace your existing goal?", "replace": "Replace it", "keepBoth": "Keep both", "cancel": "Cancel",
            "replaceText": "A goal of this type is already active. Replacing it closes the old goal but keeps its history.",
            "reasonTitle": "Why this pace?", "reasonHint": "e.g. medical supervision", "applyAnyway": "Apply anyway",
            "reasonText": "This pace is faster than usually recommended. Add your reason before applying the goal.",
            "errorTitle": "Can't apply this draft", "ok": "OK",
            "editRoutine": "Edit routine", "routine": "Routine", "name": "Name", "steps": "Steps", "workout": "Workout",
            "manual": "Manual", "activities": "Activities", "minimum": "Minimum duration", "schedule": "Schedule",
            "everyDay": "Every day", "supports": "Supports goals", "save": "Save",
            "reviewDraft": "Review draft",
        ].mapValues(\.localizedCatalogValue)
    }
}
