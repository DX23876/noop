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
        await perform(op, args: args, reader: reader)
    }

    private static func perform(_ op: String, args: [String: Any], reader: StoreReader) async -> String {
        // The plan book needs no engine: it is the shared store the coach's tools write into.
        if op.hasPrefix("coach.plan") { return CorePlan.run(op, args: args) }
        // The daily check-in needs no engine either: the learned wake time and its words.
        if op == "coach.today" { return CoreRead.json(await TodayCoachCard(reader: reader)) }
        if op == "coach.checkin" { return CoreRead.json(await CheckInState(reader: reader, fixedMinutes: args["fixedMinutes"] as? Int ?? 480)) }
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
        case "coach.brief":
            // The morning brief as iOS writes it in the background (`generateBriefText`): appended to the chat
            // as the day's brief, and returned for the notification and the widget.
            let text = await coach.generateBriefText()
            return CoreRead.json(["text": text ?? ""])
        case "coach.morning", "coach.morning.set", "coach.morning.confirmWake", "coach.morning.decide":
            return CoreRead.json(await morning(op, coach, args))
        case "coach.regenerate":
            coach.regenerate()
            return CoreRead.json(State(coach))
        case "coach.deeper":
            coach.regenerateDeeply()
            return CoreRead.json(State(coach))
        case "coach.reclaim":
            // "Edit and ask again": the last question back into the composer, its exchange removed.
            let question = coach.reclaimLastQuestion()
            return CoreRead.json(Reclaim(question: question, state: State(coach)))
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
        case "coach.settings":
            return CoreRead.json(SettingsState(coach))
        case "coach.settings.set":
            if let raw = args["persona"] as? String, let v = CoachPersona(rawValue: raw) { coach.persona = v }
            if let raw = args["verbosity"] as? String, let v = CoachVerbosity(rawValue: raw) { coach.verbosity = v }
            if let raw = args["proactive"] as? String, let v = ProactiveLevel(rawValue: raw) { coach.proactiveLevel = v }
            if let v = args["emoji"] as? Bool { coach.allowEmoji = v }
            if let v = args["autoSummarize"] as? Bool { coach.autoSummarize = v }
            if let v = args["memoryModel"] as? String { coach.memoryModel = v }
            if let v = args["cardModel"] as? String { coach.cardModel = v }
            if let v = args["deepModel"] as? String { coach.deepModel = v }
            // A quick preset writes its bundle where each control reads it (`CoachPreset.apply`); the voice
            // lives in the identity the core stores.
            if let raw = args["preset"] as? String, let preset = CoachPreset(rawValue: raw) {
                let v = preset.values
                coach.persona = v.persona
                coach.allowEmoji = v.allowEmoji
                coach.proactiveLevel = v.proactiveLevel
                coach.verbosity = v.verbosity
                var identity = CoreCoachIdentity.load()
                identity.voice = v.voice
                CoreCoachIdentity.save(identity)
            }
            if let raw = args["accessMode"] as? String, let mode = CoachDataAccessMode(rawValue: raw),
               let purposes = mode.purposes {
                coach.toolConsent.enabled = purposes
            }
            if let raw = args["purpose"] as? String, let purpose = CoachPurpose(rawValue: raw), let on = args["on"] as? Bool {
                if on { coach.toolConsent.enabled.insert(purpose) } else { coach.toolConsent.enabled.remove(purpose) }
            }
            return CoreRead.json(SettingsState(coach))
        case "coach.memory", "coach.memory.add", "coach.memory.update", "coach.memory.remove", "coach.memory.expire",
             "coach.memory.unexpire", "coach.memory.clear", "coach.memory.confirm":
            let memory = CoachMemory.shared
            let id = (args["id"] as? String).flatMap(UUID.init(uuidString:))
            switch op {
            case "coach.memory.add":
                let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let category = (args["category"] as? String).flatMap(CoachMemory.Category.init(rawValue:)) ?? .other
                if !text.isEmpty { _ = memory.add(text, category: category, confirmedByUser: true) }
            case "coach.memory.update":
                if let id, let text = args["text"] as? String { _ = memory.update(id, text: text, confirmedByUser: true) }
            case "coach.memory.remove": if let id { memory.remove(id) }
            case "coach.memory.expire": if let id { memory.setValidUntil(id, Date()) }
            case "coach.memory.unexpire": if let id { memory.setValidUntil(id, nil) }
            case "coach.memory.clear": memory.clearAll()
            case "coach.memory.confirm": if let id { memory.confirm(id) }
            default: break
            }
            return CoreRead.json(MemoryState(memory))
        case "coach.prompt", "coach.prompt.set":
            // The coach instructions the editor shows and changes (`customSystemPrompt`); blank restores the default.
            if op == "coach.prompt.set", let prompt = args["prompt"] as? String { coach.customSystemPrompt = prompt }
            return CoreRead.json(["prompt": coach.customSystemPrompt, "custom": coach.hasCustomSystemPrompt ? "1" : ""])
        case "coach.card":
            // "Ask coach" on a Today metric (`TodayView`'s card context): a short read on the card model, then the
            // card's follow-ups. The read runs in the background; the chat follows it through `coach.state`.
            let title = args["title"] as? String ?? ""
            coach.openedFromCard(CoachCardContext(
                title: title, summary: args["summary"] as? String ?? "",
                suggestions: [String(localized: "What does this mean for me?"),
                              String(localized: "Is this good, or something to watch?")]))
            Task { @MainActor in await coach.runCardAnalysisIfNeeded() }
            return #"{"ok":true}"#
        case "coach.card.allowed":
            // Whether a metric card may offer "Ask coach": iOS hides the card buttons when the Data access
            // purposes a card read draws on are off (`CoachCardContext.isAllowed`); the read would stop silently.
            // Data access itself is Kotlin's to check (`AiKeyStore.readConsent`), which hands it in on configure.
            return CoreRead.json(["allowed": CoachCardContext(title: "", summary: "").isAllowed(by: coach.toolConsent)])
        case "coach.test":
            // "Test connection" (`connectionTestRow`): the coach's own wire format, no health data read.
            await coach.testConnection()
            let line: String
            var ok = false
            switch coach.connectionTest {
            case .ok(let model): line = String(localized: "Works — \(model) replied."); ok = true
            case .failed(let message): line = message
            default: line = ""
            }
            return CoreRead.json(["ok": ok ? "1" : "", "line": line])
        case "coach.info", "coach.info.ack":
            // The first-use note and "How Coach works" (`CoachFirstUseSheet`, `CoachInfoView`).
            if op == "coach.info.ack" { UserDefaults.standard.set(true, forKey: CoachInfoState.acknowledgedKey) }
            return CoreRead.json(CoachInfoState(coach))
        case "coach.identity":
            return CoreRead.json(IdentityState(CoreCoachIdentity.load()))
        case "coach.identity.set":
            var identity = CoreCoachIdentity.load()
            if let raw = args["preset"] as? String {
                identity = raw == "marv" ? CoachIdentity.marv : CoachIdentity.svea
            }
            if let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                identity.name = name
            }
            if let raw = args["voice"] as? String, let voice = CoachVoice(rawValue: raw) { identity.voice = voice }
            if let kind = args["avatarKind"] as? String, let value = args["avatarValue"] as? String {
                switch kind {
                case "preset": identity.avatar = .preset(value)
                case "bundled": identity.avatar = .bundled(value)
                case "photo": identity.avatar = .photo(value)
                default: break
                }
            }
            CoreCoachIdentity.save(identity)
            return CoreRead.json(IdentityState(identity))
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
        // The Hevy key Android keeps in its own secure store, so the coach's Hevy tools see a connection as on iOS.
        if let hevy = args["hevyKey"] as? String {
            if hevy.isEmpty { HevyCredentials.clear() } else { HevyCredentials.save(hevy) }
        }
    }

    /// "Edit and ask again": the question taken back, and the chat after its exchange was removed.
    struct Reclaim: Encodable {
        var question: String?
        var state: State
    }

    /// What the chat screen draws: the active conversation's turns, whether a reply is streaming, and the error.
    struct State: Encodable {
        struct Point: Encodable { var date: Double, value: Double }
        struct Chart: Encodable { var title: String, kind: String, points: [Point], lo: Double, hi: Double }
        struct Row: Encodable { var label: String, value: String }
        struct Card: Encodable { var kind: String, title: String, value: String, caption: String?, rows: [Row], tint: String }
        struct Message: Encodable {
            var id: String, role: String, text: String
            var date: Double = 0
            /// "Your daily brief — the coach got in touch" and the like, for a message the coach started.
            var gotInTouch: String?
            /// The evidence chain: its header and the name of each source the reply read.
            var evidenceHeader: String?
            var evidence: [String] = []
            var chart: Chart?
            var card: Card?
            /// The memory receipt (`memoryReceipt`): what this reply saved, looked up by id so a forgotten
            /// fact drops out and an edited one shows its new text.
            var saved: [Saved] = []
        }
        struct Saved: Encodable { var id: String, line: String, text: String, confirmed: Bool }
        /// The receipt's controls, worded by the iOS catalogue: confirm, edit, forget and the edit dialog's title.
        var receiptLabels = ["confirm": "That's right".localizedCatalogValue, "edit": "Edit".localizedCatalogValue,
                             "forget": "Forget".localizedCatalogValue, "editTitle": "Edit fact".localizedCatalogValue,
                             "cancel": "Cancel".localizedCatalogValue, "save": "Save".localizedCatalogValue]
        var messages: [Message]
        var sending: Bool
        var error: String?
        var configured: Bool
        /// The coach's name, as the iOS chat header and greeting show it (the default identity on Android).
        var name = CoreCoachIdentity.load().name

        /// "reauthenticate", "retry" or "none", from the typed error behind `error`, and how long a retry waits.
        var recovery: String?
        var retryAfter: Int?
        var canDeepen = false
        /// Plan suggestions waiting for the wearer's answer: the dot on the header's plan button and its label.
        var planWaiting = 0
        var planLabel = ""
        /// Off: the chat keeps the iOS hint that answers are generic, with its way to the settings.
        var dataConsent = true
        var consentOff = "Data access is off — Coach can't see your numbers.".localizedCatalogValue
        var turnOn = "Turn on".localizedCatalogValue
        /// The follow-ups the engine offers right after a card read, ahead of the general set.
        var cardSuggestions: [String] = []
        /// The action row under the last reply (`actionRow`).
        var actionLabels = ["breathe": "Breathe".localizedCatalogValue, "live": "Live Session".localizedCatalogValue,
                            "schedule": "Schedule a session".localizedCatalogValue]

        @MainActor init(_ coach: AICoachEngine) {
            messages = coach.messages.map { m in
                var out = Message(id: m.id.uuidString, role: m.role.rawValue, text: m.text)
                out.date = m.date.timeIntervalSince1970
                out.gotInTouch = m.origin.gotInTouchLine?.localizedCatalogValue
                let tools = ChatMessage.uniqueTools(from: m.toolsUsed)
                if !tools.isEmpty {
                    out.evidenceHeader = String(localized: "Grounded in \(tools.count) of your data sources")
                    out.evidence = tools.map { $0.evidenceTitle.localizedCatalogValue }
                }
                out.saved = m.memoryWrites.compactMap { id in CoachMemory.shared.facts.first(where: { $0.id == id }) }.map { f in
                    Saved(id: f.id.uuidString,
                          line: f.verification == .pendingConfirmation
                              ? String(localized: "Saved, pending your confirmation: \(f.text)")
                              : String(localized: "Saved to memory: \(f.text)"),
                          text: f.text, confirmed: f.verification == .confirmed)
                }
                if let chart = coach.chartsByMessage[m.id] {
                    out.chart = Chart(title: chart.title, kind: chart.kind.rawValue,
                                      points: chart.values.map { Point(date: $0.date.timeIntervalSince1970, value: $0.value) },
                                      lo: chart.valueRange.lowerBound, hi: chart.valueRange.upperBound)
                }
                if let card = coach.cardsByMessage[m.id] {
                    out.card = Card(kind: card.kind.rawValue, title: card.title, value: card.value, caption: card.caption,
                                    rows: card.rows.map { Row(label: $0.label, value: $0.value) }, tint: card.tintName)
                }
                return out
            }
            if let r = coach.lastError?.recovery {
                switch r {
                case .reauthenticate: recovery = "reauthenticate"
                case .retry(let after): recovery = "retry"; retryAfter = after
                case AICoachError.Recovery.none: recovery = "none"
                }
            }
            canDeepen = coach.hasDeepAnalysisModel
            planWaiting = CoachPlanStore.shared.pending.count
            planLabel = planWaiting == 0 ? "Your plan".localizedCatalogValue
                : String(localized: "Your plan, \(planWaiting) waiting for your decision")
            dataConsent = coach.dataConsent
            cardSuggestions = coach.cardSuggestions
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
    struct Reminder: Encodable { var id: String, at: Double, title: String, body: String }
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
        if op == "coach.plan.reminders" {
            let scale = EffortScale(rawValue: args["effortScale"] as? String ?? "") ?? .hundred
            return CoreRead.json(["reminders": reminders(store.proposals, scale: scale, now: Date())])
        }
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

    /// What `PlanReminder.schedule` posts: every agreed, not yet done session with a time still ahead.
    static func reminders(_ proposals: [PlanProposal], scale: EffortScale, now: Date) -> [Reminder] {
        let title = "Time for your planned session".localizedCatalogValue
        return proposals.compactMap { p in
            guard p.status.isCommitment, p.status != .completed, let time = p.time, time > now else { return nil }
            return Reminder(id: p.id.uuidString, at: time.timeIntervalSince1970, title: title, body: p.summary(effortScale: scale))
        }
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

/// The coach's identity on Android, stored as Apple's `CoachIdentityStore` stores it: one JSON blob under
/// `coach.identity` in UserDefaults. A photo is a file the Android app keeps; the identity holds its name only.
enum CoreCoachIdentity {
    static let key = "coach.identity"

    static func load() -> CoachIdentity {
        guard let data = UserDefaults.standard.data(forKey: key),
              let identity = try? JSONDecoder().decode(CoachIdentity.self, from: data) else { return .default }
        return identity
    }

    static func save(_ identity: CoachIdentity) {
        if let data = try? JSONEncoder().encode(identity) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// The identity as the Android editor draws it.
struct IdentityState: Encodable {
    var name: String, avatarKind: String, avatarValue: String, voice: String
    var symbols = CoachAvatar.presetSymbols

    init(_ identity: CoachIdentity) {
        name = identity.name
        voice = identity.voice.rawValue
        switch identity.avatar {
        case .preset(let s): avatarKind = "preset"; avatarValue = s
        case .bundled(let s): avatarKind = "bundled"; avatarValue = s
        case .photo(let s): avatarKind = "photo"; avatarValue = s
        }
    }
}

/// The coaching and data-access settings as the iOS settings pages show them, every label from the iOS catalogue.
struct SettingsState: Encodable {
    struct Choice: Encodable { var id: String, label: String, detail: String }
    struct Purpose: Encodable { var id: String, label: String, detail: String, on: Bool }
    var persona: String, personas: [Choice]
    var verbosity: String, verbosities: [Choice]
    var proactive: String, proactives: [Choice]
    var emoji: Bool, autoSummarize: Bool, autoSummarizeDetail: String
    var accessMode: String, accessModes: [Choice]
    var purposes: [Purpose]
    /// Quick presets, the background models per role and the usage counters, as the iOS Coaching and Connection
    /// pages hold them. The master switch is Android's own (`NoopPrefs.coachEnabled`), handed in by `configure`.
    var presets: [Choice]
    var memoryModel: String, cardModel: String, deepModel: String
    var usage: [Usage] = []
    struct Usage: Encodable { var title: String, line: String, detail: String? }
    /// The words of those cards, from the iOS catalogue.
    var labels: [String: String] = [:]

    @MainActor init(_ coach: AICoachEngine) {
        presets = CoachPreset.allCases.map {
            Choice(id: $0.rawValue, label: $0.title.localizedCatalogValue, detail: $0.subtitle.localizedCatalogValue)
        }
        memoryModel = coach.memoryModel; cardModel = coach.cardModel; deepModel = coach.deepModel
        let words: [String: String] = [
            "presets": "Quick presets",
            "presetsDetail": "Sets persona, voice, emoji, proactive messages, and reply length together — tweak any of them below afterward.",
            "models": "Background models",
            "modelsDetail": "Optional cheaper models for chat summaries or a manually requested card read. You do not need to choose one for normal coaching, tools or saved facts.",
            "summary": "Chat summaries", "summaryDetail": "Distils a finished chat so the coach can recall it later.",
            "card": "Card analyses", "cardDetail": "A short read when you ask the coach about one health card.",
            "deep": "Closer look",
            "deepDetail": "An optional heavier model for \"Look at this more closely\" on a reply. Leave unset to hide that option.",
            "deepOff": "Off — no closer-look option",
            "feature": "Enable AI Coach",
            "featureOn": "Coach entry points and optional check-ins are available. Data sharing is still a separate choice.",
            "featureOff": "Off by default. Turn this on after you choose to use a provider; chats and local data stay saved.",
            "usage": "Usage so far",
            "usageNote": "Counted on-device from what your provider reports back — not every request format reports usage, so this may undercount rather than overcount.",
            "info": "How Coach works",
            "test": "Test connection", "testing": "Checking…",
            "today": "Show Coach on Today",
            "todayDetail": "Turn off to hide the Coach card and floating button. Per-metric “Ask coach” and the AI that writes your card summaries keep working.",
            "todayAvatar": "Show coach avatar",
            "todayAvatarDetail": "Use your coach’s picture on the Today entry instead of a plain icon.",
        ]
        labels = words.mapValues { $0.localizedCatalogValue }
        let log = CoachUsageLog.shared
        if let turn = log.lastTurn, !turn.rounds.isEmpty {
            usage.append(Usage(title: "Last question".localizedCatalogValue, line: CoachUsageLog.summaryLine(for: turn),
                               detail: CoachUsageLog.cacheVerdict(for: turn)))
        }
        if log.dayQuestionCount > 0 {
            usage.append(Usage(title: "Today".localizedCatalogValue,
                               line: CoachUsageLog.cumulativeSummaryLine(for: log.dayTotal, questionCount: log.dayQuestionCount),
                               detail: nil))
            usage.append(Usage(title: "This session".localizedCatalogValue,
                               line: CoachUsageLog.cumulativeSummaryLine(for: log.sessionTotal,
                                                                         questionCount: log.sessionQuestionCount),
                               detail: nil))
        }
        persona = coach.persona.rawValue
        personas = CoachPersona.allCases.map {
            Choice(id: $0.rawValue, label: $0.title.localizedCatalogValue, detail: $0.subtitle.localizedCatalogValue)
        }
        verbosity = coach.verbosity.rawValue
        verbosities = CoachVerbosity.allCases.map {
            Choice(id: $0.rawValue, label: $0.label.localizedCatalogValue, detail: $0.blurb.localizedCatalogValue)
        }
        proactive = coach.proactiveLevel.rawValue
        proactives = ProactiveLevel.allCases.map {
            Choice(id: $0.rawValue, label: $0.label.localizedCatalogValue, detail: $0.blurb.localizedCatalogValue)
        }
        emoji = coach.allowEmoji
        autoSummarize = coach.autoSummarize
        autoSummarizeDetail = (coach.autoSummarize
            ? "On: when you move on from a chat, a cheap model distils it so the coach remembers it later. Sends that chat to your provider."
            : "Off: past chats aren't summarised; the coach only recalls saved facts.").localizedCatalogValue
        let enabled = coach.toolConsent.enabled
        accessMode = CoachDataAccessMode.current(for: enabled).rawValue
        let modeLabels: [CoachDataAccessMode: String] = [.essentials: "Essentials", .personal: "Personal",
                                                         .deepInsights: "Deep insights", .expert: "Expert"]
        accessModes = CoachDataAccessMode.allCases.map {
            Choice(id: $0.rawValue, label: (modeLabels[$0] ?? $0.rawValue).localizedCatalogValue, detail: "")
        }
        // The rows of the iOS Data access page, in its order and words.
        let rows: [(CoachPurpose, String, String)] = [
            (.coreBiometrics, "Core biometrics", "Charge, sleep detail, readiness and charge drivers."),
            (.longHistory, "Long-term trend", "A compact local trend across months or years"),
            (.workouts, "Workouts", "Recent workouts, zone minutes and session outlook."),
            (.planning, "Planning", "Suggesting sessions and checking what you actually did."),
            (.stress, "Stress", "Today's derived stress index."),
            (.logs, "Logging", "Reading and logging caffeine, journal entries and Lab Book markers."),
            (.sensitiveLogs, "Sensitive journal", "Sexual, relationship, illness and cannabis entries need an extra choice."),
            (.memory, "Memory tools", "Saving, correcting and forgetting facts, and searching past chats."),
            (.patterns, "Also share my patterns & Lab Book",
             enabled.contains(.patterns)
                ? "On: a short summary of your strongest patterns and logged health numbers is added. Summaries only, never raw readings."
                : "Off: only your core metrics are shared, not your patterns or Lab Book."),
        ]
        purposes = rows.map { Purpose(id: $0.0.rawValue, label: $0.1.localizedCatalogValue,
                                      detail: $0.2.localizedCatalogValue, on: enabled.contains($0.0)) }
    }
}

/// The coach's memory as the iOS Memory page lists it: each fact with its category, where it came from and
/// whether it has expired, and the categories a new fact can take.
struct MemoryState: Encodable {
    struct Fact: Encodable {
        var id: String, text: String, category: String, categoryLabel: String, source: String
        var active: Bool, expires: Double?, sensitive: Bool
    }
    struct Category: Encodable { var id: String, label: String }
    var facts: [Fact]
    var categories: [Category]

    @MainActor init(_ memory: CoachMemory) {
        facts = memory.facts.map { f in
            let source: String
            switch f.source {
            case .user: source = "You told the coach this."
            case .coachTool: source = "The coach saved this during a conversation."
            case .conversationSummary: source = "Distilled from a past conversation."
            case .legacy: source = "Saved before the coach recorded where facts came from."
            }
            return Fact(id: f.id.uuidString, text: f.text, category: f.category.rawValue,
                        categoryLabel: f.category.label.localizedCatalogValue, source: source.localizedCatalogValue,
                        active: memory.isActive(f), expires: f.validUntil?.timeIntervalSince1970,
                        sensitive: f.sensitivity != .ordinary)
        }
        categories = CoachMemory.Category.allCases.map { Category(id: $0.rawValue, label: $0.label.localizedCatalogValue) }
    }
}


/// The first-use note shown once before the first conversation, and the fuller "How Coach works" page, in the iOS
/// words. Android leaves out the two paragraphs about the iPhone's on-device semantic search, which it does not have.
struct CoachInfoState: Encodable {
    /// `CoachFirstUse.acknowledgedKey` on Apple.
    static let acknowledgedKey = "coach.firstUseAcknowledged"
    struct Point: Encodable { var title: String, body: String }
    struct Section: Encodable { var title: String, paras: [String] }
    var acknowledged: Bool
    var firstTitle: String, firstSubtitle: String, more: String, gotIt: String
    var points: [Point]
    var infoTitle: String, done: String
    var sections: [Section]

    @MainActor init(_ coach: AICoachEngine) {
        func l(_ key: String) -> String { key.localizedCatalogValue }
        acknowledged = UserDefaults.standard.bool(forKey: Self.acknowledgedKey)
        firstTitle = l("Before you talk to your coach")
        firstSubtitle = l("A quick, honest heads-up — not fine print.")
        more = l("How it works, and exactly what's shared")
        gotIt = l("Got it")
        points = [
            Point(title: l("It's only as good as its model"),
                  body: l("The coach's judgement is the model's judgement. A small or cheap model gives shallow, generic answers; a capable one reasons well over your numbers.")),
            Point(title: l("It's support, not the last word"),
                  body: l("Treat its answers as a helpful second opinion. Don't follow them blindly — keep using your own judgement.")),
            Point(title: l("It's not a doctor, therapist or trainer"),
                  body: l("For anything medical, or anything that really matters, talk to a qualified professional. The coach can be wrong and can miss context you didn't share.")),
            coach.dataConsent
                ? Point(title: l("It works with your data"),
                        body: l("To answer well, it sends a short summary of your relevant metrics to the provider you chose — using your own key, and only when you ask. Nothing is sent otherwise."))
                : Point(title: l("It needs your data, off by default"),
                        body: l("Data sharing is OFF right now, so answers stay generic. Turn on \"Let the coach use my data\" in Settings → Privacy & data to have it answer from your real metrics — using your own key, and only when you ask.")),
        ]
        infoTitle = l("How Coach works")
        done = l("Done")
        let device = String(localized: "this \(l("phone"))")
        let provider = coach.provider.displayName
        sections = [
            Section(title: l("How it works"), paras: [
                l("NOOP first interprets your question locally. Its local data planner checks which categories you allowed and prepares only the relevant compact context — for example recovery, workouts, a journal pattern or a long-term aggregate. The provider never gets direct access to your database."),
                l("The model then writes the answer in plain language. When a specific number is needed, it can use a permitted tool; NOOP checks that tool locally before returning a result."),
            ]),
            Section(title: l("What stays here, what's sent"), paras: [
                String(localized: "Everything is computed on \(device). The coach is the ONE feature in NOOP that talks to the internet."),
                l("When you ask a question with data sharing on, it sends a short text summary or a permitted tool result to your chosen provider — never raw sensor streams or unrestricted database access. With data sharing off, it sends only your question. Nothing leaves until you ask or opt into a Coach automation."),
                l("Deep historical questions use on-device aggregates, not years of daily rows. Sensitive journal information is excluded unless you separately allow it in Data access for an explicitly sensitive question."),
            ]),
            Section(title: l("Provider & model"), paras: [
                String(localized: "You bring your own API key. The provider — right now \(provider) — is who actually receives your data, so it's the real privacy choice: pick one you trust, and check how they handle it."),
                l("The coaching model runs the conversation. Background models for chat summaries or card reads are optional and off unless you set them up (Settings → Connection & model). NOOP never sends more personal data than a request needs."),
            ]),
            Section(title: l("Why the model matters"), paras: [
                l("The coach is only as sharp as the model behind it. A stronger model reasons better over your data and gives advice worth acting on; a weak or very cheap one tends to be shallow or generic. That's why the default coaching model is a capable one, not a mini one — a bad first answer is a bad first impression for no reason you chose."),
            ]),
            Section(title: l("Its limits"), paras: [
                l("It's a support tool, not a medical or clinical authority. It can be wrong, it can miss context you didn't tell it, and it never replaces professional advice. Use it to think — not to obey."),
            ]),
            Section(title: l("Turn it off any time"), paras: [
                l("More → AI Coach lets you disable the whole feature. Its buttons, Today entries and check-ins disappear, while your on-device chats and health data remain saved unless you remove them yourself."),
            ]),
        ]
    }
}

/// The daily check-in as the iOS card words it (`checkInBar`), with the wake time it follows in its "When I wake
/// up" mode, learned from the last nights by the shared rule (`CoachCheckInWake`) over the core's sleep.
struct CheckInState: Encodable {
    var wakeMinutes: Int?
    var labels: [String: String]

    init(reader: StoreReader, fixedMinutes: Int) async {
        let now = Int(Date().timeIntervalSince1970)
        let offset = TimeZone.current.secondsFromGMT()
        let sessions = await reader.allSleepSessions(from: now - (CoachCheckInWake.nights + 5) * 86_400, to: now + 86_400)
        let midsleep = await reader.habitualMidsleepSec(from: now - 4000 * 86_400, to: now + 86_400, offsetSec: offset)
        let minutes = CoachCheckInWake.mainNightWakeMinutes(
            blocks: sessions.map { (start: $0.effectiveStartTs, end: $0.endTs) }, nights: CoachCheckInWake.nights,
            habitualMidsleepSec: midsleep)
        wakeMinutes = CoachCheckInWake.habitualWakeMinutes(fromLocalMinutes: minutes)
        func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        let words: [String: String] = [
            "title": "Daily check-in", "on": "On: a daily reminder to open your coaching brief.",
            "off": "Off: the coach only responds when you ask.", "fixed": "Fixed time", "wake": "When I wake up",
            "time": "Time", "denied": "Notifications are off. Enable them for NOOP in Settings to use check-ins.",
            "notifTitle": "Your coach has today's brief", "notifBody": "Open NOOP for your readiness and today's plan.",
            "planTitle": "Plan reminders", "planOn": "On: a reminder at the time you set for a planned session.",
            "planOff": "Off: sessions with a time don't remind you.",
            "planDenied": "Notifications are off. Enable them for NOOP in Settings to use reminders.",
        ]
        labels = words.mapValues { $0.localizedCatalogValue }
        if let wake = wakeMinutes {
            let at = clock(wake)
            labels["wakeReadout"] = String(localized: "Tracks your wake time — around \(at) lately. Refreshes each time you open NOOP.")
        } else {
            let fallback = clock(fixedMinutes)
            labels["wakeReadout"] = String(localized: "Learning your wake time from your sleep. Until there's enough, it uses your fixed time (\(fallback)).")
        }
    }
}

/// The coach card on Today (`DashboardCoachCard`) and the words of its launcher (`CoachLauncherSheet`). The sentence
/// is Momentum's own read of today (`MomentumCopy.stateDetail`), so the card can never tell the wearer something
/// different from Today's Momentum card.
/// The morning suggestion on Today (`MorningSuggestionCard`): the card's state resolved by the shared
/// `MorningSuggestionState`, its words from the iOS catalogue, and the switch (`coach.morningSuggestion`).
struct MorningSuggestion: Encodable {
    var on: Bool
    var kind: String
    var id: String?, title: String?, summary: String?, rationale: String?
    /// The detected wake (unix seconds) and the sentence about it, `%@` standing for the time.
    var wake: Int?, wakeText: String?
    var labels: [String: String]
}

extension CoreCoach {
    static let morningKey = "coach.morningSuggestion"
    private static var unsettledWake: Int?

    /// Reads the card; `.set` switches it, `.decide` accepts or declines the waiting proposal, `.confirmWake`
    /// vouches for the detected wake. With `generate` it first runs the day's brief as Today opening does on
    /// iOS (`maybeGenerate`), which may take as long as a reply.
    static func morning(_ op: String, _ coach: AICoachEngine, _ args: [String: Any]) async -> MorningSuggestion {
        let defaults = UserDefaults.standard
        if op == "coach.morning.set" { defaults.set(args["on"] as? Bool ?? false, forKey: morningKey) }
        if op == "coach.morning.decide", let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)) {
            if args["accept"] as? Bool == true { CoachPlanStore.shared.accept(id) } else { CoachPlanStore.shared.decline(id) }
        }
        var generate = args["generate"] as? Bool == true
        if op == "coach.morning.confirmWake" {
            CoachBriefStamp.confirmWake(day: LogicalDay.key(Date()))
            unsettledWake = nil
            generate = true
        }
        let on = defaults.bool(forKey: morningKey)
        if generate, on, coach.isConfigured, coach.dataConsent, !coach.sending {
            await coach.startBriefIfNeeded()
            unsettledWake = await coach.unconfirmedWakeNeedingReview()
        }
        let scale = EffortScale(rawValue: args["effortScale"] as? String ?? "") ?? .hundred
        let state = MorningSuggestionState.resolve(
            morningOn: on, configured: coach.isConfigured, consent: coach.dataConsent,
            toolsActive: coach.toolCallingActive, sending: coach.sending,
            pending: CoachPlanStore.shared.pending, today: StoreReader.localDayKey(Date()), unsettledWake: unsettledWake)
        return card(state, on: on, scale: scale)
    }

    /// The card for one resolved state, worded from the iOS catalogue.
    static func card(_ state: MorningSuggestionState, on: Bool, scale: EffortScale) -> MorningSuggestion {
        let labels = [
            "setting": "Morning suggestion on Today", "note": "Needs a connected provider and data access, so the coach has something to suggest from.",
            "generating": "Working out today's session…", "accept": "Accept", "change": "Change", "decline": "Not this one",
            "wakeTitle": "Check last night first", "wakeHint": "This usually means the strap hasn't finished syncing yet.",
            "confirm": "That's right", "fix": "Fix it",
        ].mapValues(\.localizedCatalogValue)
        var out = MorningSuggestion(on: on, kind: "hidden", labels: labels)
        switch state {
        case .hidden: break
        case .generating: out.kind = "generating"
        case .waiting(let p):
            out.kind = "waiting"
            out.id = p.id.uuidString
            out.title = (p.intent == .rest ? "Rest day suggested" : p.intent == .mobility ? "Mobility suggested" : "Today's session")
                .localizedCatalogValue
            out.summary = p.summary(effortScale: scale)
            out.rationale = p.rationale
        case .confirmWake(let wake):
            out.kind = "confirmWake"
            out.wake = wake
            out.wakeText = "Your strap recorded you waking at %@. If that's not right, today's recovery is off — and so would any plan built on it be.".localizedCatalogValue
        }
        return out
    }
}

struct TodayCoachCard: Encodable {
    var overline: String, greeting: String, detail: String, badge: String
    var intro: String, ask: String, cancel: String, title: String

    @MainActor init(reader: StoreReader, now: Date = Date()) async {
        let todayKey = LogicalDay.key(now)
        let from = StoreReader.localDayKey(now.addingTimeInterval(-2 * 86_400))
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))
        let days = StoreReader.mergeDaily(imported: await reader.unionDailyMetrics(from: from, to: to),
                                          computed: await reader.unionComputedDailyMetrics(from: from, to: to))
        let display = days.last { $0.day == todayKey }
        overline = "\("Your coach".localizedCatalogValue) \(CoreCoachIdentity.load().name)".uppercased()
        let h = Calendar.current.component(.hour, from: now)
        let greet = h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        greeting = "\(greet.localizedCatalogValue) \(h < 17 ? "☀️" : "🌙")"
        detail = MomentumCopy.stateDetail(display)
        badge = "Today's recommendation".localizedCatalogValue
        intro = "Ask about your charge, effort, rest and workouts, grounded in your own numbers.".localizedCatalogValue
        ask = "Ask your coach…".localizedCatalogValue
        cancel = "Cancel".localizedCatalogValue
        title = "Coach".localizedCatalogValue
    }
}
