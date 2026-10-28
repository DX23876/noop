import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The shared coach (`AICoachEngine`) for the Android screens (Android parity plan, Coach extraction): one engine
/// over the store the shadow session opened, driven by `CoreCall` operations. Kotlin keeps the settings screen
/// and the encrypted key store; it hands both in with `coach.configure` before the coach is used, and reads the
/// transcript back with `coach.state` while a reply streams.
@MainActor
enum CoreCoach {
    private static var engine: AICoachEngine?
    private static var engineDeviceId: String?

    /// The engine for this store and strap, made on first use. The data host reads its days and recent nights
    /// once here, as `Repository` has them loaded on Apple.
    private static func engine(reader: StoreReader, settings: CoreGoals.Settings) async -> AICoachEngine {
        if let engine, engineDeviceId == reader.activeDeviceId { return engine }
        let data = CoreCoachData(reader: reader, settings: settings)
        await data.load()
        let made = AICoachEngine(repo: data, memory: coachMemoryIndex())
        engine = made
        engineDeviceId = reader.activeDeviceId
        return made
    }

    static func run(_ op: String, args: [String: Any], reader: StoreReader) async -> String {
        // The plan book needs no engine: it is the shared store the coach's tools write into.
        if op.hasPrefix("coach.plan") { return CorePlan.run(op, args: args) }
        let coach = await engine(reader: reader, settings: CoreGoalEnergy.settings(args))
        let id = (args["id"] as? String).flatMap(UUID.init(uuidString:))
        switch op {
        case "coach.configure":
            configure(coach, args)
            return CoreRead.json(["configured": coach.isConfigured])
        case "coach.send":
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !coach.sending else { return #"{"ok":false}"# }
            coach.startSend(text)
            return #"{"ok":true}"#
        case "coach.state":
            return CoreRead.json(State(coach))
        case "coach.new":
            coach.newConversation()
            return CoreRead.json(State(coach))
        case "coach.stop":
            coach.stop()
            return CoreRead.json(State(coach))
        case "coach.conversations":
            return CoreRead.json(Conversations(coach))
        case "coach.switch":
            if let id { coach.switchTo(id) }
            return CoreRead.json(Conversations(coach))
        case "coach.rename":
            if let id { coach.renameConversation(id, to: args["title"] as? String ?? "") }
            return CoreRead.json(Conversations(coach))
        case "coach.delete":
            if let id { coach.deleteConversation(id) }
            return CoreRead.json(Conversations(coach))
        case "coach.archive":
            if let id { coach.setArchived(id, args["value"] as? Bool ?? true) }
            return CoreRead.json(Conversations(coach))
        case "coach.pin":
            if let id { coach.setPinned(id, args["value"] as? Bool ?? true) }
            return CoreRead.json(Conversations(coach))
        default:
            return #"{"error":"unknownOp"}"#
        }
    }

    /// The Android settings in the engine's terms. The key goes to the in-memory secret vault for this process,
    /// owned by the selected provider, so `isConfigured` reads it as Apple's Keychain key.
    private static func configure(_ coach: AICoachEngine, _ args: [String: Any]) {
        // Android's own master switch (`NoopPrefs.coachEnabled`) in the place the engine checks it.
        if let enabled = args["enabled"] as? Bool {
            UserDefaults.standard.set(enabled, forKey: CoachFeaturePrefs.enabledKey)
        }
        if let raw = args["provider"] as? String, let provider = AIProvider(rawValue: raw), coach.provider != provider {
            coach.provider = provider
        }
        if let model = args["model"] as? String, !model.isEmpty, coach.model != model { coach.model = model }
        if let consent = args["consent"] as? Bool, coach.dataConsent != consent { coach.dataConsent = consent }
        if let url = args["customBaseUrl"] as? String, coach.customBaseURL != url { coach.customBaseURL = url }
        if let raw = args["customAuthHeader"] as? String, let header = CustomAIAuthHeader(rawValue: raw),
           coach.customAuthHeader != header {
            coach.customAuthHeader = header
        }
        if let connected = args["customConnected"] as? Bool, coach.customConnected != connected {
            coach.customConnected = connected
        }
        let key = args["key"] as? String ?? ""
        if key.isEmpty { AIKeyStore.clear() } else { AIKeyStore.save(key, owner: coach.provider.rawValue) }
    }

    /// What the chat screen draws: the active conversation's turns, whether a reply is streaming, and the error.
    struct State: Encodable {
        struct Message: Encodable { var id: String, role: String, text: String }
        var messages: [Message]
        var sending: Bool
        var error: String?
        var configured: Bool

        @MainActor init(_ coach: AICoachEngine) {
            messages = coach.messages.map { Message(id: $0.id.uuidString, role: $0.role.rawValue, text: $0.text) }
            sending = coach.sending
            error = coach.errorText
            configured = coach.isConfigured
        }
    }

    /// The history list as `CoachHistoryView` draws it: every thread, newest first, with the preview line.
    struct Conversations: Encodable {
        struct Row: Encodable {
            var id: String, title: String, preview: String, updatedAt: Double, pinned: Bool, archived: Bool, active: Bool
            var searchText: String
        }
        var conversations: [Row]

        @MainActor init(_ coach: AICoachEngine) {
            conversations = coach.conversations.map { c in
                let last = c.messages.last { !$0.text.isEmpty }?.text.replacingOccurrences(of: "\n", with: " ")
                return Row(id: c.id.uuidString, title: c.title.isEmpty ? String(localized: "New chat") : c.title,
                           preview: last ?? String(localized: "No messages yet"), updatedAt: c.updatedAt.timeIntervalSince1970,
                           pinned: c.pinned, archived: c.archived, active: c.id == coach.activeConversationID,
                           searchText: ([c.title] + c.messages.map(\.text)).joined(separator: "\n"))
            }
        }
    }
}

/// The coach's plan book (`CoachPlanView`): what waits for the wearer's yes, what was agreed, and what happened,
/// with every line worded as the Apple page words it.
@MainActor
enum CorePlan {
    struct Output: Encodable {
        var pending: [Row]
        var agreed: [Row]
        var recent: [Row]
        var empty: Bool
        var skipReasons: [Choice]
        var feedbacks: [Choice]
        var intents: [Choice]
    }
    struct Row: Encodable {
        var id: String, summary: String, rationale: String, day: String, dayLabel: String, status: String
        var swappedFrom: String?, statusLine: String, feedback: String?, feedbackLabel: String?
        var sport: String, intent: String, time: Double?
    }
    struct Choice: Encodable { var id: String, label: String }

    static func run(_ op: String, args: [String: Any]) -> String {
        let store = CoachPlanStore.shared
        let id = (args["id"] as? String).flatMap(UUID.init(uuidString:))
        let time = (args["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        switch (op, id) {
        case ("coach.plan.accept", let id?): store.accept(id, at: time)
        case ("coach.plan.setTime", let id?): store.setTime(id, at: time)
        case ("coach.plan.clearTime", let id?): store.clearTime(id)
        case ("coach.plan.reschedule", let id?):
            if let day = args["day"] as? String, !day.isEmpty { store.reschedule(id, toDay: day, at: time) }
        case ("coach.plan.swap", let id?):
            let sport = (args["sport"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !sport.isEmpty {
                store.swap(id, toSport: sport, intent: (args["intent"] as? String).flatMap(PlanProposal.Intent.init(rawValue:)))
            }
        case ("coach.plan.decline", let id?): store.decline(id)
        case ("coach.plan.complete", let id?): store.complete(id)
        case ("coach.plan.skip", let id?):
            if let reason = (args["reason"] as? String).flatMap(PlanProposal.SkipReason.init(rawValue:)) {
                store.skip(id, reason: reason)
            }
        case ("coach.plan.feedback", let id?):
            if let feedback = (args["feedback"] as? String).flatMap(PlanProposal.EffectFeedback.init(rawValue:)) {
                store.recordEffect(id, feedback: feedback)
            }
        default: break
        }
        let scale = EffortScale(rawValue: args["effortScale"] as? String ?? "") ?? .hundred
        return CoreRead.json(output(store: store, scale: scale))
    }

    static func output(store: CoachPlanStore, scale: EffortScale, now: Date = Date()) -> Output {
        let today = StoreReader.localDayKey(now)
        func row(_ p: PlanProposal) -> Row {
            Row(id: p.id.uuidString, summary: p.summary(effortScale: scale), rationale: p.rationale, day: p.day,
                dayLabel: dayLabel(p.day, now: now), status: p.status.rawValue, swappedFrom: p.swappedFrom,
                statusLine: statusLine(p, now: now), feedback: p.effectFeedback?.rawValue,
                feedbackLabel: p.effectFeedback?.label.localizedCatalogValue, sport: p.sport, intent: p.intent.rawValue,
                time: p.time?.timeIntervalSince1970)
        }
        return Output(
            pending: store.pending.map(row),
            agreed: store.commitments(fromDay: today).map(row),
            recent: store.proposals.filter { $0.day < today && $0.status.isDecided }.prefix(10).map(row),
            empty: store.proposals.isEmpty,
            skipReasons: PlanProposal.SkipReason.allCases.map { Choice(id: $0.rawValue, label: $0.label.localizedCatalogValue) },
            feedbacks: PlanProposal.EffectFeedback.allCases.map { Choice(id: $0.rawValue, label: $0.label.localizedCatalogValue) },
            intents: PlanProposal.Intent.allCases.map { Choice(id: $0.rawValue, label: $0.label.localizedCatalogValue) })
    }

    /// `CoachPlanView.statusLine`: neutral wording, a skip states its reason.
    static func statusLine(_ p: PlanProposal, now: Date) -> String {
        switch p.status {
        case .completed:
            if let feedback = p.effectFeedback {
                return String(localized: "completed — \(feedback.label.localizedCatalogValue)")
            }
            return String(localized: "completed — effect not rated")
        case .skipped:
            if let reason = p.skipReason {
                return String(localized: "didn't happen — \(reason.label.localizedCatalogValue)")
            }
            return String(localized: "didn't happen")
        case .declined:
            return String(localized: "you passed on this one")
        case .rescheduled:
            if let from = p.rescheduledFrom {
                return String(localized: "moved from \(dayLabel(from, now: now).localizedCatalogValue)")
            }
            return String(localized: "moved")
        default:
            return p.status.rawValue
        }
    }

    /// `CoachPlanView.dayLabel`: Today, Tomorrow, Yesterday, else a short weekday and date.
    static func dayLabel(_ day: String, now: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: day) else { return day }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let d = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: d) { return String(localized: "Tomorrow") }
        if let d = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: d) { return String(localized: "Yesterday") }
        let out = DateFormatter(); out.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return out.string(from: date)
    }
}
