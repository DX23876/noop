import Foundation

/// The one-page goal editor (`CoachGoalEditorView`) for Android: the goal journey's "Extend the date" opens it on a
/// goal. Android holds the fields and hands them in with every call; the kind's target-date default, the range check,
/// the live pace and combined-load verdicts, the kind and ceiling gates and the save are the shared ones
/// (`GoalSafetyGate`, `GoalVolumeGate`, `CoachGoalRange`, `CoachGoalStore.commit`). Every sentence is the iOS
/// catalogue's.
@MainActor
enum CoreGoalEditor {
    struct Draft: Codable {
        var kind: String, title: String, baseline: String, target: String
        var hasTargetDate: Bool, targetDateTouched: Bool, targetDate: Double
        var motivation: String, tags: [String], share: Bool, reason: String

        init(kind: String, title: String, baseline: String, target: String, hasTargetDate: Bool, targetDateTouched: Bool,
             targetDate: Double, motivation: String, tags: [String], share: Bool, reason: String) {
            self.kind = kind; self.title = title; self.baseline = baseline; self.target = target
            self.hasTargetDate = hasTargetDate; self.targetDateTouched = targetDateTouched; self.targetDate = targetDate
            self.motivation = motivation; self.tags = tags; self.share = share; self.reason = reason
        }

        /// Decoded rather than cast field by field, as the long-term setup's state is: a missing field takes the blank
        /// draft's value, and the decoder does not depend on how each platform's Foundation bridges JSON values.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ k: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: k) ?? "" }
            func flag(_ k: CodingKeys) throws -> Bool { try c.decodeIfPresent(Bool.self, forKey: k) ?? false }
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? CoachGoal.Kind.run.rawValue
            title = try text(.title); baseline = try text(.baseline); target = try text(.target)
            hasTargetDate = try flag(.hasTargetDate); targetDateTouched = try flag(.targetDateTouched)
            targetDate = try c.decodeIfPresent(Double.self, forKey: .targetDate) ?? 0
            motivation = try text(.motivation); tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            share = try flag(.share); reason = try text(.reason)
        }
    }
    struct State: Encodable {
        var found: Bool
        var draft: Draft
        var kinds: [CoreGoalOnboarding.Kind], tags: [CoreGoalOnboarding.Tag]
        var kindNote: String?
        var quantified: Bool, placeholder: String
        var rangeIsUsable: Bool, canSave: Bool
        var warning: String?, veryAggressive: Bool
        /// The very-aggressive tier asks for a reason, unless the goal already carries an acknowledgement.
        var needsReason: Bool
        var volumeWarning: String?
        /// The gate before saving: `kind` (offer to replace `replaceId`), `full`, or nil.
        var limit: String?, replaceId: String?, hasRoom: Bool, limitText: String?
        var saved: Bool
        var labels: [String: String]
    }

    /// `goals.editor.load` reads the goal `id` into a draft; `goals.editor` judges the draft as typed;
    /// `goals.editor.kind` picks a kind (`to`); `goals.editor.save` commits it (with `acknowledging` and `replacing`).
    static func run(_ op: String, _ args: [String: Any], weightKg: Double) -> State {
        let store = CoachGoalStore.shared
        let editingId = (args["id"] as? String).flatMap(UUID.init(uuidString:))
        let existing = editingId.flatMap(store.goal(id:))
        var d = (args["draft"] as? [String: Any]).flatMap(draft(from:)) ?? existing.map(draft(of:)) ?? blank()
        var saved = false
        switch op {
        case "goals.editor.kind":
            if let k = (args["to"] as? String).flatMap(CoachGoal.Kind.init(rawValue:)) {
                d.kind = k.rawValue
                // Follow the kind's default until the wearer has an opinion of their own.
                if !d.targetDateTouched { d.hasTargetDate = k.isQuantified }
            }
        case "goals.editor.save":
            guard existing != nil else { break }
            let goal = coachGoal(d)
            let safety = GoalSafetyGate.assess(goal: goal, bodyWeightKg: weightKg)
            let acknowledging = flag(args["acknowledging"])
            let ack = acknowledging ? CoachGoalRisk.acknowledgement(verdict: safety.verdict.rawValue, reason: d.reason) : nil
            let clearStale = !acknowledging && (safety.verdict == .ok || safety.verdict == .notApplicable)
            let replacing = (args["replacing"] as? String).flatMap(UUID.init(uuidString:))
            store.commit(goal, editingId: editingId, replacing: replacing, acknowledgedRisk: ack, clearStaleAck: clearStale)
            saved = true
        default: break
        }
        return state(d, editingId: editingId, found: existing != nil, weightKg: weightKg, saved: saved)
    }

    /// A JSON boolean, whether Foundation hands it over as `Bool` or as `NSNumber`.
    static func flag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        return (value as? NSNumber)?.boolValue ?? false
    }

    static func draft(from raw: [String: Any]) -> Draft? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(Draft.self, from: data)
    }

    /// An existing goal's own answers, as the editor's `load` fills its fields.
    static func draft(of g: CoachGoal) -> Draft {
        Draft(kind: g.kind.rawValue, title: g.title,
              baseline: g.baseline.map { String(format: "%g", $0) } ?? "",
              target: g.target.map { String(format: "%g", $0) } ?? "",
              hasTargetDate: g.targetDate != nil, targetDateTouched: true,
              targetDate: (g.targetDate ?? Date().addingTimeInterval(60 * 24 * 3600)).timeIntervalSince1970,
              motivation: g.motivation, tags: g.motivationTags.map(\.rawValue), share: g.shareMotivation, reason: "")
    }

    static func blank() -> Draft {
        Draft(kind: CoachGoal.Kind.run.rawValue, title: "", baseline: "", target: "",
              hasTargetDate: CoachGoal.Kind.run.isQuantified, targetDateTouched: false,
              targetDate: Date().addingTimeInterval(60 * 24 * 3600).timeIntervalSince1970,
              motivation: "", tags: [], share: false, reason: "")
    }

    /// The goal as currently typed, the editor's `draft`.
    static func coachGoal(_ d: Draft) -> CoachGoal {
        let tags = Set(d.tags.compactMap(CoachGoal.MotivationTag.init(rawValue:)))
        return CoachGoal(kind: CoachGoal.Kind(rawValue: d.kind) ?? .run, title: d.title,
                         baseline: CoachGoalRange.value(d.baseline), target: CoachGoalRange.value(d.target),
                         targetDate: d.hasTargetDate ? Date(timeIntervalSince1970: d.targetDate) : nil,
                         motivation: d.motivation,
                         motivationTags: CoachGoal.MotivationTag.allCases.filter { tags.contains($0) },
                         shareMotivation: d.share)
    }

    static func state(_ d: Draft, editingId: UUID?, found: Bool, weightKg: Double, saved: Bool) -> State {
        let store = CoachGoalStore.shared
        let goal = coachGoal(d)
        let kind = goal.kind
        let safety = GoalSafetyGate.assess(goal: goal, bodyWeightKg: weightKg)
        let volume = GoalVolumeGate.assess(draft: goal, against: store.activeGoals, excludingId: editingId)
        let range = CoachGoalRange.isUsable(kind: kind, baselineText: d.baseline, targetText: d.target)
        var kindNote: String?
        if kind == .weight {
            kindNote = "I'll track your weight and plan your training around it — but I have no nutrition data, and that's where most of weight change is decided. I won't pretend otherwise.".localizedCatalogValue
        } else if !kind.isQuantified {
            kindNote = "I can hold this goal and shape your training around it, but I can't measure it from your strap — so I won't invent progress numbers for it.".localizedCatalogValue
        }
        let kindLabel = kind.label.localizedCatalogValue
        var limit: String?, replaceId: String?, limitText: String?
        switch store.canAdd(kind: kind, replacing: editingId) {
        case .kindAlreadyActive(let id)?:
            limit = "kind"; replaceId = id.uuidString
            limitText = String(format: "You already have an active %@ goal. Replacing it closes that one out — its story stays in your history.".localizedCatalogValue, kindLabel)
        case .tooManyActive?:
            limit = "full"
            limitText = String(format: "You already have %lld active goals — set one aside or close one out before adding another.".localizedCatalogValue,
                               CoachGoalStore.maxActiveGoals)
        case nil: break
        }
        let existingAck = editingId.flatMap { store.goal(id: $0)?.acknowledgedRisk }
        return State(
            found: found, draft: d,
            kinds: CoachGoal.Kind.templateFreeCases.map {
                CoreGoalOnboarding.Kind(id: $0.rawValue, label: $0.label.localizedCatalogValue, blurb: $0.blurb.localizedCatalogValue,
                                        quantified: $0.isQuantified, unit: $0.unit,
                                        placeholder: CoreGoalOnboarding.placeholder($0).localizedCatalogValue)
            },
            tags: CoachGoal.MotivationTag.allCases.map { CoreGoalOnboarding.Tag(id: $0.rawValue, label: $0.label.localizedCatalogValue) },
            kindNote: kindNote, quantified: kind.isQuantified,
            placeholder: CoreGoalOnboarding.placeholder(kind).localizedCatalogValue,
            rangeIsUsable: range, canSave: !d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && range,
            warning: safety.warning, veryAggressive: safety.verdict == .veryAggressive,
            needsReason: safety.requiresReason && existingAck == nil,
            volumeWarning: volume.warning,
            limit: limit, replaceId: replaceId, hasRoom: store.hasRoom(replacing: editingId), limitText: limitText,
            saved: saved, labels: labels(kind))
    }

    /// The editor's own words, `CoachGoalEditorView`'s literals.
    static func labels(_ kind: CoachGoal.Kind) -> [String: String] {
        [
            "title": "Edit goal", "cancel": "Cancel", "save": "Save", "goalType": "Goal type", "goal": "Goal",
            "from": "From (\(kind.unit))", "to": "To (\(kind.unit))", "now": "now", "targetHint": "target",
            "targetDate": "Target date", "targetDateNote": "Without one there's no route, no pace and no arrival date.",
            "sameTitle": "Start and target are the same",
            "sameText": "With the same number in both fields there's nothing to move toward: no progress, no route, no arrival date. Give the target a different value.",
            "pace": "About that pace", "volume": "About your combined training load",
            "after": "What are you really after?",
            "why": "Pick what's driving this — the coach uses it to shape its advice, not just decorate the screen.",
            "personal": "Anything more personal? (optional)", "personalHint": "the reason you'll remember at 6am",
            "share": "Share this with the coach",
            "shareOn": "Sent to your AI provider along with the rest of your context.",
            "shareOff": "Stays on this device. The coach won't see it.",
            "reasonTitle": "Why this pace?", "reasonHint": "e.g. deliberate cut phase", "saveAnyway": "Save anyway",
            "reasonText": "This is faster than usually recommended. It's your call — tell me why and I'll note it, so I coach you through it instead of arguing with you every week.",
            "replaceTitle": "Replace your existing goal?", "replace": "Replace it", "keepBoth": "Keep both",
            "limitTitle": "You're at the limit", "ok": "OK",
        ].mapValues(\.localizedCatalogValue)
    }
}
