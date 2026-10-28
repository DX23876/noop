import Foundation

/// The guided goal setup (`CoachGoalOnboardingFlow`) for Android: the wizard's state is iOS's
/// `GoalOnboardingDraft`, rebuilt from what the screen holds on every call, so the step gate, the kind's
/// target-date default, the pace check and the commit are the shared ones. Android keeps the fields and draws
/// the steps; every sentence comes from the iOS catalogue.
@MainActor
enum CoreGoalOnboarding {
    /// Set once the first-run offer was shown, saved or skipped, as `CoachView.goalOnboardingAskedKey`.
    static let askedKey = "coach.goalOnboardingAsked"

    struct Draft: Codable {
        var step: Int, kind: String, title: String, baseline: String, target: String
        var hasTargetDate: Bool, targetDateTouched: Bool, targetDate: Double
        var motivation: String, tags: [String], share: Bool, reason: String
    }
    struct Kind: Encodable { var id: String, label: String, blurb: String, quantified: Bool, unit: String, placeholder: String }
    struct Tag: Encodable { var id: String, label: String }
    struct State: Encodable {
        var draft: Draft
        var steps: Int, stepTitle: String, stepLabel: String
        var canAdvance: Bool, rangeIsUsable: Bool
        var kinds: [Kind], tags: [Tag]
        var kindNote: String?
        var goalTitle: String, summary: String
        var warning: String?, veryAggressive: Bool, requiresReason: Bool
        /// The gate before saving: `kind` (offer to replace `replaceId`), `full`, or nil.
        var limit: String?, replaceId: String?, hasRoom: Bool
        var limitText: String?
        /// Whether the first-run offer is still due: no active goal, never asked.
        var offer: Bool
        var saved: Bool
        var labels: [String: String]
    }

    /// `goals.onboarding` reads; `.kind` picks a kind, `.advance` and `.back` move, `.commit` saves (with
    /// `acknowledging` and `replacing`), `.asked` records that the first-run offer was shown.
    static func run(_ op: String, _ args: [String: Any], weightKg: Double) -> State {
        let d = GoalOnboardingDraft()
        if let raw = args["draft"] as? [String: Any] { load(d, raw) }
        var saved = false
        switch op {
        case "goals.onboarding.kind":
            if let k = (args["to"] as? String).flatMap(CoachGoal.Kind.init(rawValue:)) { d.kindChanged(to: k) }
        case "goals.onboarding.advance": d.advance()
        case "goals.onboarding.back": d.back()
        case "goals.onboarding.asked": UserDefaults.standard.set(true, forKey: askedKey)
        case "goals.onboarding.commit":
            let safety = GoalSafetyGate.assess(goal: d.goal, bodyWeightKg: weightKg)
            let acknowledging = args["acknowledging"] as? Bool == true
            let ack = acknowledging ? CoachGoalRisk.acknowledgement(verdict: safety.verdict.rawValue, reason: d.reason) : nil
            let clearStale = !acknowledging && (safety.verdict == .ok || safety.verdict == .notApplicable)
            let replacing = (args["replacing"] as? String).flatMap(UUID.init(uuidString:))
            CoachGoalStore.shared.commit(d.goal, editingId: nil, replacing: replacing, acknowledgedRisk: ack, clearStaleAck: clearStale)
            UserDefaults.standard.set(true, forKey: askedKey)
            d.reset()
            saved = true
        default: break
        }
        return state(d, weightKg: weightKg, saved: saved)
    }

    static func load(_ d: GoalOnboardingDraft, _ raw: [String: Any]) {
        d.step = GoalOnboardingDraft.Step(rawValue: raw["step"] as? Int ?? 0) ?? .welcome
        d.kind = (raw["kind"] as? String).flatMap(CoachGoal.Kind.init(rawValue:)) ?? .run
        d.title = raw["title"] as? String ?? ""
        d.baselineText = raw["baseline"] as? String ?? ""
        d.targetText = raw["target"] as? String ?? ""
        d.hasTargetDate = raw["hasTargetDate"] as? Bool ?? d.kind.isQuantified
        d.targetDateTouched = raw["targetDateTouched"] as? Bool ?? false
        if let t = (raw["targetDate"] as? NSNumber)?.doubleValue, t > 0 { d.targetDate = Date(timeIntervalSince1970: t) }
        d.motivation = raw["motivation"] as? String ?? ""
        d.motivationTags = Set((raw["tags"] as? [String] ?? []).compactMap(CoachGoal.MotivationTag.init(rawValue:)))
        d.shareMotivation = raw["share"] as? Bool ?? false
        d.reason = raw["reason"] as? String ?? ""
    }

    static func state(_ d: GoalOnboardingDraft, weightKg: Double, saved: Bool = false) -> State {
        let store = CoachGoalStore.shared
        let goal = d.goal
        let safety = GoalSafetyGate.assess(goal: goal, bodyWeightKg: weightKg)
        let kindLabel = d.kind.label.localizedCatalogValue
        var kindNote: String?
        if store.activeGoal(for: d.kind) != nil {
            kindNote = String(format: "You already have an active %@ goal — continuing will offer to replace it.".localizedCatalogValue, kindLabel)
        } else if d.kind == .weight {
            kindNote = "I'll track your weight and plan your training around it — but I have no nutrition data, and that's where most of weight change is decided. I won't pretend otherwise.".localizedCatalogValue
        } else if !d.kind.isQuantified {
            kindNote = "I can hold this goal and shape your training around it, but I can't measure it from your strap — so I won't invent progress numbers for it.".localizedCatalogValue
        }
        var parts = [String(format: "%@ goal".localizedCatalogValue, kindLabel)]
        if d.kind.isQuantified, let target = Double(d.targetText.replacingOccurrences(of: ",", with: ".")) {
            parts.append(String(format: "target %g %@", target, d.kind.unit))
        }
        if d.hasTargetDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            parts.append(String(format: "by %@".localizedCatalogValue, f.string(from: d.targetDate)))
        }
        var limit: String?, replaceId: String?, limitText: String?
        switch store.canAdd(kind: d.kind) {
        case .kindAlreadyActive(let id)?:
            limit = "kind"; replaceId = id.uuidString
            limitText = String(format: "You already have an active %@ goal. Replacing it closes that one out — its story stays in your history.".localizedCatalogValue, kindLabel)
        case .tooManyActive?:
            limit = "full"
            limitText = String(format: "You already have %lld active goals — set one aside or close one out before adding another.".localizedCatalogValue,
                               CoachGoalStore.maxActiveGoals)
        case nil: break
        }
        let steps = GoalOnboardingDraft.Step.allCases.count
        let draft = Draft(step: d.step.rawValue, kind: d.kind.rawValue, title: d.title, baseline: d.baselineText,
                          target: d.targetText, hasTargetDate: d.hasTargetDate, targetDateTouched: d.targetDateTouched,
                          targetDate: d.targetDate.timeIntervalSince1970, motivation: d.motivation,
                          tags: CoachGoal.MotivationTag.allCases.filter { d.motivationTags.contains($0) }.map(\.rawValue),
                          share: d.shareMotivation, reason: d.reason)
        return State(
            draft: draft, steps: steps, stepTitle: d.step.title.localizedCatalogValue,
            stepLabel: String(format: "Step %lld of %lld".localizedCatalogValue, d.step.rawValue + 1, steps),
            canAdvance: d.canAdvance, rangeIsUsable: d.rangeIsUsable,
            kinds: CoachGoal.Kind.templateFreeCases.map {
                Kind(id: $0.rawValue, label: $0.label.localizedCatalogValue, blurb: $0.blurb.localizedCatalogValue, quantified: $0.isQuantified, unit: $0.unit,
                     placeholder: placeholder($0).localizedCatalogValue)
            },
            tags: CoachGoal.MotivationTag.allCases.map { Tag(id: $0.rawValue, label: $0.label.localizedCatalogValue) },
            kindNote: kindNote,
            goalTitle: d.trimmedTitle.isEmpty ? "Your goal".localizedCatalogValue : d.trimmedTitle,
            summary: parts.joined(separator: " · "),
            warning: safety.warning, veryAggressive: safety.verdict == .veryAggressive, requiresReason: safety.requiresReason,
            limit: limit, replaceId: replaceId, hasRoom: store.hasRoom(), limitText: limitText,
            offer: store.activeGoals.isEmpty && !UserDefaults.standard.bool(forKey: askedKey),
            saved: saved, labels: labels(d))
    }

    /// The flow's own words, `CoachGoalOnboardingFlow`'s literals.
    static func labels(_ d: GoalOnboardingDraft) -> [String: String] {
        [
            "skip": "Skip", "back": "Back", "next": "Next", "start": "Get started", "set": "Set my goal",
            "welcome": "A few quick questions and your coach knows what you're working towards — so it can tell you where you stand, not just how you slept.",
            "optional": "Entirely optional. Everything else works without a goal, and you can change or drop it any time.",
            "goal": "Goal", "nameNote": "Give it a name to continue.",
            "from": "From (\(d.kind.unit))", "to": "To (\(d.kind.unit))", "now": "now", "targetHint": "target",
            "rangeNote": "Start and target are the same number — there'd be nothing to move toward, so no progress, no route and no arrival date.",
            "targetDate": "Target date", "targetDateNote": "Without one there's no route, no pace and no arrival date.",
            "why": "Pick what's driving this — the coach uses it to shape its advice, not just decorate the screen.",
            "personal": "Anything more personal? (optional)", "personalHint": "the reason you'll remember at 6am",
            "share": "Share this with the coach",
            "shareOn": "Sent to your AI provider along with the rest of your context.",
            "shareOff": "Stays on this device. The coach won't see it.",
            "pace": "About that pace",
            "reasonTitle": "Why this pace?", "reasonHint": "e.g. deliberate cut phase", "cancel": "Cancel", "saveAnyway": "Save anyway",
            "reasonText": "This is faster than usually recommended. It's your call — tell me why and I'll note it, so I coach you through it instead of arguing with you every week.",
            "replaceTitle": "Replace your existing goal?", "replace": "Replace it", "keepBoth": "Keep both",
            "limitTitle": "You're at the limit", "ok": "OK",
            "entry": CoachGoalStore.shared.activeGoals.isEmpty ? "Set up with a few questions" : "Add another goal",
            "entryNote": "A short, guided setup.",
        ].mapValues(\.localizedCatalogValue)
    }

    static func placeholder(_ kind: CoachGoal.Kind) -> String {
        switch kind {
        case .run:         return "e.g. Run 5k without stopping"
        case .consistency: return "e.g. Train three times a week"
        case .sleep:       return "e.g. Sleep 7.5 hours a night"
        case .strength:    return "e.g. Get back to full-body strength work"
        case .hardSets:    return "e.g. 18 hard sets a week for legs"
        case .weight:      return "e.g. Get to 78 kg"
        case .stress:      return "e.g. Fewer high-stress days each week"
        case .recovery:    return "e.g. Wake up feeling more recovered"
        case .custom, .endurance, .fitness, .body, .activity, .habit:
            return "e.g. Feel good on the hills again"
        }
    }
}
