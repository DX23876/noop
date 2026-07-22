import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport
import StrandDesign

// MARK: - AI Coach (the one networked feature, strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat, no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question - only a short text summary of your metrics goes to the provider you pick."

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }

    /// Why this message exists. Everything the coach says looks identical in the transcript, so a
    /// message the user never asked for — a morning brief, an unprompted nudge, the weekly review —
    /// reads exactly like an answer to a question they've forgotten asking. Naming the origin lets the
    /// UI say "the coach got in touch" instead, which is the honest framing for something that arrived
    /// on its own.
    enum Origin: String, Codable {
        /// A reply to something the user asked. The default, and the case for every stored message
        /// written before this field existed.
        case reply
        case brief
        case checkIn
        case nudge
        case weeklyReview

        /// Whether this arrived unprompted. `reply` is the only one that didn't.
        var isCoachInitiated: Bool { self != .reply }
    }

    let id: UUID
    let role: Role
    let text: String
    /// When the turn was created — drives time separators in the transcript. Defaulted on decode so
    /// transcripts saved before this field existed still load (they just show "now" for old turns).
    let date: Date
    /// Tool names actually called by the model to produce THIS reply, in call order (may repeat a name
    /// across rounds) — the evidence chain a user can expand to see what grounded the answer. Empty for
    /// user turns, for a plain-context-path reply (no tool-calling provider), and for turns predating
    /// this field (back-compat decode).
    let toolsUsed: [String]
    /// Why this message exists — see `Origin`. Defaulted on decode, so every stored transcript keeps
    /// loading and simply reads as ordinary replies.
    let origin: Origin

    init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(),
         toolsUsed: [String] = [], origin: Origin = .reply) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.toolsUsed = toolsUsed
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, date, toolsUsed, origin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        toolsUsed = try c.decodeIfPresent([String].self, forKey: .toolsUsed) ?? []
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .reply
    }

    /// Pure: unique tool names from `toolsUsed`, in FIRST-call order — a tool called twice across rounds
    /// (e.g. re-checking readiness after a swap) only needs to be listed once in the evidence chain
    /// (P6). Unrecognised names are dropped rather than shown as a raw identifier. No view dependency —
    /// unit-tested.
    static func uniqueTools(from toolsUsed: [String]) -> [CoachTool] {
        var seen = Set<String>()
        var result: [CoachTool] = []
        for name in toolsUsed {
            guard seen.insert(name).inserted, let tool = CoachTool(rawValue: name) else { continue }
            result.append(tool)
        }
        return result
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API key. Uses a generic-password item under a fixed
/// service so the key never lands in UserDefaults, a plist, or on disk in the clear.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// UserDefaults key recording which provider the stored API key belongs to, so one provider's key
    /// is never sent to another provider's endpoint (above all the arbitrary user-typed Custom URL).
    private static let ownerKey = "ai.keyProvider"

    /// The provider the stored key was saved for, or nil for a legacy key saved before this tracking.
    static var ownerProvider: String? { UserDefaults.standard.string(forKey: ownerKey) }

    /// Store (or replace) the API key for `owner`. Empty/whitespace input is treated as a clear.
    /// Returns true once the key is in the Keychain (or was cleared); false if the Keychain write
    /// failed, in which case the owner marker is left untouched so it never points at a key that
    /// isn't actually stored (#872). The live `read()`/`hasKey` gating already reads the real
    /// Keychain, so this is defensive tidying of the discarded write result, not a behaviour change.
    @discardableResult
    static func save(_ key: String, owner: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(owner, forKey: ownerKey)
        return true
    }

    /// Read the stored API key, or nil if none is set.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Remove any stored API key.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
/// `Equatable` is synthesized (every associated value is): the UI compares the current failure to decide
/// whether a countdown should restart, and the tests assert on the CASE rather than its rendered
/// sentence — matching a localized string would pass in English and fail in German.
enum AICoachError: LocalizedError, Equatable {
    case noKey
    case emptyQuestion
    case badKey
    /// `retryAfter`: seconds from the provider's `Retry-After` header, when it sent one. Carrying it
    /// turns "wait a moment" into a countdown the user can act on instead of guess at.
    case rateLimited(retryAfter: Int?)
    case server(Int, String)
    case network(String)
    /// No usable connection. Split out of `.network` because the two need opposite responses: an
    /// offline device needs "you're offline", not a CFNetwork string, and retrying immediately is
    /// pointless rather than worth a button.
    case offline
    case decode
    case keySaveFailed
    case badCustomURL(String)
    case noModel

    /// The user-actionable follow-up this failure deserves, if any. The UI reads this instead of
    /// pattern-matching the error itself, so a new case can't quietly ship with no way forward.
    enum Recovery: Equatable {
        /// The key was rejected — send the user to where they can paste a new one.
        case reauthenticate
        /// Worth retrying, optionally only after `seconds`.
        case retry(after: Int?)
        /// Nothing the app can do; the text explains it.
        case none
    }

    var recovery: Recovery {
        switch self {
        case .badKey:                    return .reauthenticate
        case .rateLimited(let after):    return .retry(after: after)
        case .offline, .network, .decode: return .retry(after: nil)
        case .server(let code, _):
            // 5xx is the provider's problem and usually transient; a 4xx is ours and retrying it
            // unchanged just fails again.
            return (500...599).contains(code) ? .retry(after: nil) : .none
        case .noKey, .noModel, .emptyQuestion, .keySaveFailed, .badCustomURL:
            return .none
        }
    }

    var errorDescription: String? {
        switch self {
        case .badCustomURL(let message):
            return message
        case .noKey:
            return "Add your own API key first to use the coach."
        case .noModel:
            // Reachable mainly on the Custom provider, whose model list starts empty on purpose. Say
            // what to do rather than forwarding the server's 400, which reads as if the request itself
            // were malformed.
            return "Pick a model first. Tap Refresh next to Model in Coach settings to load the ones "
                + "your provider offers, or type an id yourself."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited(let after):
            if let after {
                return "The provider is rate-limiting requests. It asked to wait \(after) seconds."
            }
            return "The provider is rate-limiting requests right now. Wait a moment and try again."
        case .offline:
            // No CFNetwork prose: the cause is plain, and the coach is the only part of NOOP that needs
            // a connection at all — worth saying, so an offline user doesn't think the app is broken.
            return "You're offline. The coach needs a connection; everything else in NOOP keeps working."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        }
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    /// All saved conversations, most-recently-updated first. The visible chat is the ACTIVE one; older
    /// ones stay findable in the history sheet instead of being overwritten.
    @Published private(set) var conversations: [CoachConversation] = []
    /// The conversation currently shown in the chat. `messages` reads/writes into this one.
    @Published var activeConversationID: UUID?
    @Published var sending = false
    @Published var errorText: String?
    /// The same failure as `errorText`, but TYPED, so the error row can offer the right way forward
    /// (re-authenticate / retry / nothing) instead of pattern-matching a localized sentence — which
    /// would break in every language but English.
    @Published private(set) var lastError: AICoachError?

    /// Record a failure for the UI. Classifies anything that isn't already an `AICoachError` through
    /// `coachTransportError`, so an offline device reads as offline wherever it surfaced — the
    /// providers' own streaming paths throw raw `URLError`s that used to arrive here as CFNetwork prose.
    func setError(_ error: Error) {
        let coachError = (error as? AICoachError) ?? coachTransportError(error)
        lastError = coachError
        errorText = coachError.errorDescription
    }

    /// Clear both halves together: a lingering `lastError` would leave a stale "Retry" under a chat
    /// that has since succeeded.
    func clearError() {
        errorText = nil
        lastError = nil
    }

    /// The active conversation, if any.
    var activeConversation: CoachConversation? {
        guard let id = activeConversationID else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    /// The visible transcript: a computed view over the active conversation, so every existing call site
    /// that appends/removes/subscripts `messages` keeps working unchanged. Writing it also bumps the
    /// conversation's `updatedAt`, re-sorts most-recent-first, and auto-titles from the first user turn.
    var messages: [ChatMessage] {
        get { activeConversation?.messages ?? [] }
        set {
            guard let id = activeConversationID,
                  let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
            conversations[idx].messages = newValue
            conversations[idx].updatedAt = Date()
            if conversations[idx].title.isEmpty || conversations[idx].title == "New chat" {
                conversations[idx].title = CoachConversation.autoTitle(from: newValue)
            }
            // Keep most-recently-updated first without disturbing the active id.
            conversations.sort { $0.updatedAt > $1.updatedAt }
        }
    }
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            // A switch mid-stream would leave the old provider's request in flight while `model` is
            // re-pointed underneath it — cancel first, keeping whatever already streamed.
            stop()
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
            resetConnectionTest()   // the previous verdict described a different provider
        }
    }
    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: Self.modelKey)
            // A tick earned by another model says nothing about this one — the endpoint can accept the
            // key and still refuse the model.
            if model != oldValue { resetConnectionTest() }
        }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// OpenRouter model ids confirmed to support tool-calling (from `/models`' `supported_parameters`),
    /// populated by `refreshModels()` / `ensureOpenRouterCapabilities()`. `toolCallingActive`
    /// (`CoachTools.swift`) reads this to gate the tool path per model — not every model behind
    /// OpenRouter can take tool definitions. NOT reset by a provider switch (see `provider.didSet`):
    /// a stale set for a model no longer selected is simply never consulted.
    ///
    /// PERSISTED, and that is load-bearing: as a plain in-memory `@Published` this emptied on every
    /// launch, so `toolCallingActive` went false and an OpenRouter user silently lost every tool —
    /// `propose_plan` included — until they happened to tap "Refresh models" again. That made the whole
    /// plan/suggestion feature a no-op for them, once per launch, with no UI hint anything was off.
    @Published var openRouterToolCapableModels: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(openRouterToolCapableModels), forKey: Self.orToolCapableKey)
        }
    }
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default, until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// Cloud-provider counterpart to `customConnected` — whether the user has explicitly disconnected
    /// (Settings' Disconnect button) since the last time they saved a key or reconnected. Never touches
    /// `AIKeyStore` itself; see `disconnect()`/`reconnect()`. (#P4 4.2/4.3)
    @Published var explicitlyDisconnected: Bool {
        didSet { UserDefaults.standard.set(explicitlyDisconnected, forKey: Self.explicitlyDisconnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }
    /// The cheap/fast model used for background memory maintenance (summarising chats + distilling
    /// facts), kept separate from the coaching `model` so that work never burns the pricier model.
    /// Defaults to `provider.cheapModel`; editable in settings. Empty falls back to the coaching model.
    /// This is the `.summary` role's override (see `CoachModelRole` / `model(for:)`).
    @Published var memoryModel: String {
        didSet { UserDefaults.standard.set(memoryModel, forKey: Self.memoryModelKey) }
    }
    /// The cheap/fast model used for short one-off CARD analyses (the `.cardAnalysis` role). Empty →
    /// falls back to `provider.cheapModel`, then the coaching model. Configured in settings; consumed by
    /// the card-AI feature. Separate from `memoryModel` so the two background jobs can be tuned apart.
    /// The optional heavier model for a "go deeper on this one" re-run. Empty by default — see
    /// `CoachModelRole.deepAnalysis` for why depth is a model rather than a reasoning flag.
    @Published var deepModel: String {
        didSet { UserDefaults.standard.set(deepModel, forKey: Self.deepModelKey) }
    }

    /// Whether the deep re-run is available at all. The UI hides the action entirely when it isn't,
    /// rather than offering something that would quietly resolve back to the ordinary chat model and
    /// return an identical answer the user just paid twice for.
    var hasDeepAnalysisModel: Bool {
        !deepModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @Published var cardModel: String {
        didSet { UserDefaults.standard.set(cardModel, forKey: Self.cardModelKey) }
    }
    /// Whether the coach auto-summarises a conversation (via the cheap model) when the user moves on from
    /// it, feeding cross-conversation memory. ON by default; gated behind `dataConsent` at run time.
    @Published var autoSummarize: Bool {
        didSet { UserDefaults.standard.set(autoSummarize, forKey: Self.autoSummarizeKey) }
    }
    /// How chatty the coach is allowed to be UNPROMPTED (#P10 10.4). A proactive message costs tokens, so
    /// this is a user dial: `off` silences it, `important` limits it to setbacks + big wins, `normal` also
    /// celebrates smaller wins and adds a light weekly review. Defaults to `important` — present but
    /// conservative, never chatty.
    @Published var proactiveLevel: ProactiveLevel {
        didSet { UserDefaults.standard.set(proactiveLevel.rawValue, forKey: ProactiveLevel.storageKey) }
    }

    /// Emoji in coach replies (#P14 7.3) — off by default; read fresh into `emojiClause` on every prompt.
    @Published var allowEmoji: Bool {
        didSet { UserDefaults.standard.set(allowEmoji, forKey: Self.allowEmojiKey) }
    }

    /// Card-AI (#P11): the metric card the user tapped "Ask coach" on, consumed once when the Coach opens
    /// (`runCardAnalysisIfNeeded`). Set via `openedFromCard`; cleared as it's read so a later plain open
    /// doesn't re-run the analysis.
    @Published var pendingCardContext: CoachCardContext?
    /// Metric-specific follow-up questions offered as chips after a card read (11.3). Cleared on the next
    /// user turn so they don't linger past the moment they belong to.
    @Published var cardSuggestions: [String] = []

    private let repo: Repository
    private let session: URLSession

    /// Closure `AppModel` wires right after constructing the engine, so the coach can read the LIVE
    /// illness signal (`IllnessSignalEngine.Result`, already evaluated by `AppModel` off journal +
    /// day-history confounder context) without the engine holding a reference to `AppModel` — mirrors
    /// the `diagnosticSink` closure-wiring pattern `IntelligenceEngine` already uses. Returns nil until
    /// the first evaluation runs, or when nothing anomalous has been detected.
    var illnessSignalProvider: (() -> IllnessSignalEngine.Result?)?

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    /// True once the user has explicitly tapped Disconnect on a CLOUD provider — kept separate from
    /// `AIKeyStore` entirely (#P4 4.3: disconnect must never delete the stored key, only stop using it).
    /// Defaults false (not disconnected), so an existing user who already has a key saved from before
    /// this flag existed reads as still connected — no migration step needed.
    private static let explicitlyDisconnectedKey = "ai.explicitlyDisconnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    /// `.summary` and `.cardAnalysis` role override keys — kept in sync with `CoachModelRole`'s own
    /// `overrideDefaultsKey` (the single source of truth), used here only for the `init` restore + the
    /// `didSet` writes above. `memoryModelKey` pre-dates the role system, hence the name.
    private static let memoryModelKey = CoachModelRole.summary.overrideDefaultsKey!
    private static let cardModelKey = CoachModelRole.cardAnalysis.overrideDefaultsKey!
    private static let deepModelKey = CoachModelRole.deepAnalysis.overrideDefaultsKey!
    private static let autoSummarizeKey = "ai.autoSummarize"
    /// Emoji in coach replies (#P14 7.3) — off by default, matching the careful/human register the P13
    /// voice clause already asks for; a user who wants a lighter touch can opt in.
    private static let allowEmojiKey = "ai.allowEmoji"
    /// The logical day (rolls 04:00, same as the rest of the app) the last daily brief was generated on
    /// for ANY conversation — so at most one auto-brief lands per day, and a conversation reopened after
    /// a day boundary gets a fresh one instead of showing Monday's brief on Friday.
    private static let lastBriefDayKey = "ai.lastBriefDay"
    /// The logical day the last CHECK-IN ran. Deliberately SEPARATE from `lastBriefDayKey`: a check-in is
    /// its own thing (it reflects on what happened, it doesn't re-brief), so a morning brief must not
    /// suppress the evening check-in, nor the other way round. (T6)
    private static let lastCheckInDayKey = "ai.lastCheckInDay"
    /// The logical day the last PROACTIVE nudge fired, and the logical day the last WEEKLY review ran —
    /// separate locks so neither crowds out the brief/check-in, and a nudge lands at most once a day and
    /// a review at most once a week. (#P10)
    private static let lastProactiveDayKey = "ai.lastProactiveDay"
    private static let lastWeeklyReviewDayKey = "ai.lastWeeklyReviewDay"
    /// Backs `openRouterToolCapableModels`. Stored as an array (UserDefaults has no Set type); order is
    /// irrelevant, only membership is ever read.
    private static let orToolCapableKey = "ai.openRouterToolCapableModels"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    Your source of truth is the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    HRV, resting heart rate) and recent workouts — provided below as a summary, or fetched with your \
    tools. Charge is the daily recovery/readiness score, effort is the daily cardiovascular load score, \
    and rest is the nightly sleep-quality score. \
    Coach using autoregulation:
    • Readiness → prescription: your autoregulation input is a Readiness verdict computed the SAME way \
    the app's own Today screen shows it - level (primed/balanced/strained/rundown), acute:chronic \
    workload ratio, training monotony, and the contributing signals. FOLLOW that verdict rather than \
    re-deriving your own call from the raw charge number, so your advice never contradicts what the \
    user sees on Today. primed = green light to build/push, higher effort is fine; balanced = \
    maintain, quality over volume, keep it controlled; strained/rundown = active recovery only (Zone 2, \
    mobility, extra sleep) and protect against accumulating effort debt. If a HEALTH SIGNAL / SAFETY note \
    is present, do not suggest increasing training load regardless of the readiness level.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating - like a coach who knows them.
    • Plans are AGREED, not issued. A declined or skipped session is information, not a failure - the \
    skip reason is usually right there, so ask about it rather than assuming laziness.
    When you have no data to work from, coach generally and invite them to turn on data access for \
    personalised advice. You are NOT a doctor - never diagnose; suggest a professional for genuine \
    health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans, ### headings only when structure genuinely helps, and a \
    small table only for a week-ahead plan. No code blocks.
    """

    // MARK: Plan-tool clauses — appended by `systemPrompt` according to whether the tools EXIST
    //
    // These used to live inside `defaultSystemPrompt` as one unconditional sentence, which was a lie
    // whenever `send()` passed `tools: []` (a provider without tool-calling, or data consent off): the
    // model was told to "record it with propose_plan" and would faithfully report having done so, while
    // nothing was ever created. The user then had nothing to accept — the proposal never existed.
    //
    // Appending them in `systemPrompt` rather than baking them into the default ALSO closes a second
    // hole: a user with a custom `ai.systemPrompt` override used to lose the plan rule entirely. Now
    // they get it, and — more to the point — they can never get the wrong one.

    /// Sent when `propose_plan` / `get_session_outlook` are genuinely on the wire.
    static let planToolClause = """
    When you recommend a session, record it with propose_plan - that creates a proposal the user \
    accepts, changes or declines in the app. It is NOT scheduled until they say yes, so never describe \
    it as booked. Also use propose_plan when the USER states their own plain-language training intent \
    for a specific day (e.g. "I'm going for a run today", "let's do legs tomorrow") - record what they \
    said they're doing, even though you didn't suggest it yourself, so it shows up for them to confirm. \
    If they want to swap a session, use get_session_outlook to tell them what their own history says it \
    costs, then let them choose: inform, never overrule.
    """

    /// Sent when no tools are offered. The last sentence is the whole point of this clause.
    static let noPlanToolClause = """
    You have no tools this turn: you cannot record, schedule or look anything up for the user. When you \
    recommend a session, say so plainly and tell them to add it themselves in Your plan if they want it. \
    Never claim you've noted, recorded, saved or scheduled anything - you haven't.
    """

    /// Explainability (#P12 12.3): appended to EVERY prompt (tool and non-tool), so the coach shows the
    /// ground under its claims instead of asserting them bare — and so a user with a custom system prompt
    /// still gets the rule. It asks for the SOURCE, not a raw-data dump (12.2): the metric/window the
    /// claim rests on, named in the sentence, phrased in one mode-appropriate way.
    static let citationClause = """
    Show your ground. When you state a number, a trend, or a training call, name where it comes from in \
    the same breath — the tool you just called, or the specific metric and time window from the data \
    summary you were given (e.g. "your HRV is down ~12ms on your 30-day average" or "readiness says \
    maintain"). Don't dump raw data or list every figure; cite the one or two that actually drive each \
    point, so the user can see what the advice rests on. If you don't have the data for a claim, say so \
    plainly rather than asserting it.
    """

    /// Coach voice (#P13 7.2): appended to EVERY prompt, under the chosen persona. It keeps the human,
    /// careful register the whole product wants — plain sentences over hype, and honesty over false
    /// medical certainty — so a persona can be warm or demanding without tipping into cheesy or
    /// pseudo-clinical. Deliberately says nothing about emoji: that is a user setting handled in P14.
    static let voiceClause = """
    However your style reads, sound like a real, careful human coach. Plain, natural sentences — not a \
    hype account, not a greeting card, not a textbook. No exclamation-point spray, no cheesy \
    affirmations, no buzzwords. Never speak with false medical certainty and never diagnose; when the \
    data is thin or something sounds clinical, say what you can actually see and point them to a \
    professional. Your confidence comes from the data you cite, not from volume.
    """

    /// Emoji in replies (#P14 7.3) — a user-set dial, appended after the voice clause so it reads as a
    /// narrow exception to it rather than a competing instruction.
    static let emojiOnClause = "You may use the ODD, well-placed emoji if it genuinely fits — never more than one per message, and never in a serious or cautionary line."
    static let emojiOffClause = "Do not use emoji."

    /// The emoji clause matching `allowEmoji`'s current value.
    var emojiClause: String { allowEmoji ? Self.emojiOnClause : Self.emojiOffClause }

    /// Reply language: nothing else in this prompt ever states one, so without this the model tends to
    /// default to English regardless of the app's own language (the app UI is fully localized via the
    /// string catalog, but that says nothing about what language the MODEL writes in). Read fresh from
    /// `Locale.current` — the system/app language, same source every other formatter in the app already
    /// reads (`SleepMark`, `TodayView`, …) — so a language change takes effect on the next message with
    /// no engine rebuild, same posture as the rest of `systemPrompt`. Named in English on purpose: this
    /// is an instruction TO the model, not text it should echo back.
    var languageClause: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English"
        return """
        Reply in \(name) (\(code)) - that's the app's current language. Keep numbers, units, and proper \
        nouns as they are; translate everything else. If the user writes to you in a different language, \
        follow their lead for that reply instead.
        """
    }

    /// The tool-awareness map, appended to the CACHED system block when tools are live (same
    /// `toolCallingActive` gate as `planToolClause`). It lands in the system block — cached by Anthropic
    /// after round 1 — rather than in a per-round user message, where its predecessor
    /// (`toolModeContextNote`) was re-paid uncached every round. Written as a four-VERB map, not a list
    /// of 20 names: the model already has all 20 full tool definitions in the same request, so what it
    /// needs is a sense of the families and the discipline to reach for them, not the names repeated.
    static let toolModeClause = """
    Nothing about this user is in front of you until you fetch it — reach for a tool before you answer, \
    not after guessing. What your tools do:
    • READ their data — get_biometric_summary, get_readiness, get_charge_drivers, get_sleep_detail, \
    get_recent_workouts, get_stress_index, get_zone_minutes, get_range_report, get_plan_adherence, \
    get_my_logs (read back what they logged — caffeine, journal, lab, hydration, mood), plot_metric to \
    draw one, and get_personal_patterns when they've shared it. Call get_readiness before any \
    push/maintain/rest call; never re-derive that from the raw charge number.
    • PROJECT forward — get_session_outlook (what a session would cost, from their own history), \
    simulate_day (tomorrow's Charge under a plan).
    • WRITE to the app — propose_plan, log_caffeine, log_journal, log_lab_marker; always say plainly \
    what you wrote.
    • REMEMBER across chats — remember_fact, update_fact, forget_fact, and search_past_conversations \
    to pull earlier context back.
    Cite the real numbers a tool returns; if one reports no data, say so rather than inventing figures. \
    Two tool calls and an answer you can stand behind beat one confident sentence you can't.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (stored?.isEmpty == false) ? stored! : Self.defaultSystemPrompt
        // The coach's IDENTITY (#R9) leads: its name and phrasing lean, so the model knows WHO it is
        // (Svea / Marv / a custom name) — the "who" axis. Then the selected persona sets the STYLE (how it
        // decides and how hard it holds you) on top of the methodology in `base`. Both read fresh so a
        // change to either applies on the very next message. Name comes from the identity, behaviour from
        // the persona — they never fight over "who you are".
        var prompt = CoachIdentityStore.shared.identity.identityPreamble
            + "\n\n" + persona.systemPreamble + "\n\n" + base
        // Persistent memory: the user's goal + PINNED facts (injuries, hard constraints) ride every
        // prompt. Query-relevant normal facts are injected per-question in `wireMessages` instead, so a
        // large memory doesn't bloat every request. Read fresh so a fact pinned THIS turn frames the next.
        let memory = CoachMemory.shared.pinnedBlock
        if !memory.isEmpty { prompt += "\n\n" + memory }
        // Tell the model the truth about what it can DO this turn. Both this and `send`'s
        // `tools: toolCallingActive ? coachTools : []` read the same gate on the same MainActor turn,
        // so the promise and the tool array can never disagree.
        prompt += "\n\n" + (toolCallingActive ? Self.planToolClause : Self.noPlanToolClause)
        // The tool-awareness map rides the cached system block (not a per-round user message) so the
        // model is reminded what its tools are for at ~1/10th the per-round cost. Same gate as above.
        if toolCallingActive { prompt += "\n\n" + Self.toolModeClause }
        // Explainability (#P12): always ask the coach to name the source under each claim — in both
        // modes, and after the tool/plan clauses so it reads as the closing discipline on top of them.
        prompt += "\n\n" + Self.citationClause
        // Coach voice (#P13): the human/careful register, under whichever persona leads the prompt.
        prompt += "\n\n" + Self.voiceClause
        // Reply language: read fresh so a system/app language change applies on the next message, same
        // as everything else in this property.
        prompt += "\n\n" + languageClause
        // Emoji (#P14 7.3): a user-set dial, read fresh so a settings change applies next message.
        prompt += "\n\n" + emojiClause
        return prompt
    }

    /// The active coaching personality. Backed by UserDefaults via `CoachPersona`; the setter
    /// signals `objectWillChange` so the settings picker updates, mirroring `customSystemPrompt`.
    var persona: CoachPersona {
        get { CoachPersona.current }
        set {
            CoachPersona.set(newValue)
            objectWillChange.send()
        }
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    init(repo: Repository, session: URLSession = .shared) {
        self.repo = repo
        self.session = session

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        // Restore which OpenRouter models are known tool-capable. Direct assignment in `init` doesn't
        // fire `didSet`, so this doesn't write straight back — same as `model`/`provider` above.
        self.openRouterToolCapableModels =
            Set(UserDefaults.standard.stringArray(forKey: Self.orToolCapableKey) ?? [])

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.explicitlyDisconnected = UserDefaults.standard.bool(forKey: Self.explicitlyDisconnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
        // Role model OVERRIDES: restore the user's explicit choice, or empty. Empty is the honest
        // default — `model(for:)` then resolves it to the provider's cheap model DYNAMICALLY, so it
        // always matches the current provider (an earlier version baked the cheap model in at init, which
        // went stale across a provider switch). auto-summarise defaults ON.
        self.memoryModel = UserDefaults.standard.string(forKey: Self.memoryModelKey) ?? ""
        self.cardModel = UserDefaults.standard.string(forKey: Self.cardModelKey) ?? ""
        self.deepModel = UserDefaults.standard.string(forKey: Self.deepModelKey) ?? ""
        self.autoSummarize = (UserDefaults.standard.object(forKey: Self.autoSummarizeKey) as? Bool) ?? true
        self.proactiveLevel = UserDefaults.standard.string(forKey: ProactiveLevel.storageKey)
            .flatMap(ProactiveLevel.init(rawValue:)) ?? .important
        self.allowEmoji = UserDefaults.standard.bool(forKey: Self.allowEmojiKey)

        // Restore saved conversations (migrating a legacy single transcript on first run) so history
        // survives a relaunch. Start on the most-recent one, or a fresh empty conversation.
        var restored = CoachConversationStore.load()
        restored.sort { $0.updatedAt > $1.updatedAt }
        if restored.isEmpty { restored = [CoachConversation()] }
        self.conversations = restored
        self.activeConversationID = restored.first?.id

        // Keep the list saved: a debounced sink (not a didSet) so token-by-token streaming doesn't
        // hammer the disk.
        transcriptAutosave = $conversations
            .dropFirst()
            .debounce(for: .seconds(1.0), scheduler: DispatchQueue.main)
            .sink { CoachConversationStore.save($0) }

        // Rebuild the in-memory chart artifacts for the active conversation from their snapshots.
        rebuildChartsForActive()

        // Archive yesterday's untouched brief threads on launch (#R8) so they don't accumulate in the
        // main list. The active thread is exempt; if it's itself a stale brief, the next brief opens a
        // new thread and this sweep catches the old one then.
        archiveStaleAutoThreads()
    }

    /// Debounced transcript persistence (see init).
    private var transcriptAutosave: AnyCancellable?

    // MARK: Conversation management (history)

    /// Start a new conversation and switch to it. If the active one is already empty, reuse it rather
    /// than piling up blank threads. Preserved name `clearChat` as an alias so old call sites still work.
    func newConversation() {
        if let cur = activeConversation, cur.messages.isEmpty {
            chartsByMessage = [:]
            clearError()
            return
        }
        if let leaving = activeConversationID { maybeSummarize(leaving) }
        let fresh = CoachConversation()
        conversations.insert(fresh, at: 0)
        activeConversationID = fresh.id
        chartsByMessage = [:]
        clearError()
    }

    /// Back-compat alias for the old "New chat" button.
    func clearChat() { newConversation() }

    /// Switch the visible chat to another saved conversation, restoring its charts. Summarise the one
    /// being left first (cheap model, best-effort) so its content becomes cross-conversation memory.
    func switchTo(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        if let leaving = activeConversationID, leaving != id { maybeSummarize(leaving) }
        activeConversationID = id
        clearError()
        rebuildChartsForActive()
    }

    /// Move a conversation into (or out of) the history's Archived section (#R8). The manual companion to
    /// the automatic sweep: the user can archive a thread themselves, or restore one the sweep tucked away.
    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].archived = archived
    }

    /// Whether an unprompted coach message is waiting to be seen — the badge on the Today entry and the
    /// floating button.
    ///
    /// "Unread" is derived, not tracked: a coach-initiated message counts until the user takes a turn
    /// after it or opens the thread it landed in (`markCoachMessagesSeen`). A separate read-state store
    /// would be a second source of truth to keep in sync with the transcript for no gain.
    var hasUnseenCoachMessage: Bool {
        guard let seen = UserDefaults.standard.object(forKey: Self.lastSeenCoachMessageKey) as? Double
        else {
            return conversations.contains { $0.messages.contains { $0.origin.isCoachInitiated } }
        }
        let seenAt = Date(timeIntervalSince1970: seen)
        return conversations.contains { convo in
            convo.messages.contains { $0.origin.isCoachInitiated && $0.date > seenAt }
        }
    }

    /// Mark everything the coach said on its own as seen. Called when the chat is opened — the point at
    /// which the user has actually been shown it.
    func markCoachMessagesSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSeenCoachMessageKey)
        objectWillChange.send()   // `hasUnseenCoachMessage` is computed
    }

    private static let lastSeenCoachMessageKey = "coach.lastSeenCoachMessageAt"

    /// Pin or unpin a conversation. A pinned thread sorts to the top of the history AND is exempt from
    /// the 50-conversation cap (`CoachConversationStore.applyCap`) — pinning something and having it
    /// silently deleted later would defeat the point of pinning it.
    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].pinned = pinned
    }

    /// Rename a conversation (user-set titles are kept; auto-titling won't overwrite them).
    func renameConversation(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[idx].title = trimmed.isEmpty ? "New chat" : trimmed
    }

    /// Delete a conversation. If it was the active one, fall back to the newest remaining, or a fresh one.
    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeConversationID == id || activeConversationID == nil {
            if let first = conversations.first {
                activeConversationID = first.id
            } else {
                let fresh = CoachConversation()
                conversations = [fresh]
                activeConversationID = fresh.id
            }
            rebuildChartsForActive()
        }
    }

    /// Rebuild `chartsByMessage` for the active conversation from its persisted snapshots.
    private func rebuildChartsForActive() {
        guard let convo = activeConversation else { chartsByMessage = [:]; return }
        var map: [UUID: CoachChartArtifact] = [:]
        for (idStr, snap) in convo.charts {
            if let id = UUID(uuidString: idStr) { map[id] = snap.artifact }
        }
        chartsByMessage = map
    }

    // MARK: Send control (start / stop / regenerate)

    /// The in-flight send, held so the UI can Stop it mid-stream.
    private var sendTask: Task<Void, Never>?

    /// Kick off a send as a cancellable task. The composer calls this instead of awaiting `send`
    /// directly, so `stop()` can cancel it.
    func startSend(_ text: String) {
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            await self?.send(text)
            // Always clears — including on error, cancellation and Stop. A deep turn that failed must
            // not leave the next ordinary question silently routed to the expensive model.
            self?.deepTurn = false
        }
    }

    /// Stop an in-flight reply. Whatever streamed so far stays in the transcript; no error is shown.
    func stop() {
        sendTask?.cancel()
        sendTask = nil
        sending = false
        // Disarm here as well as in `startSend`'s continuation: a stopped deep run must not leave the
        // next ordinary question routed to the expensive model, and Stop is the one path where the user
        // has explicitly said they don't want this request finished.
        deepTurn = false
    }

    /// Whether the CURRENT request should go to the deep-analysis model. Scoped to one turn and cleared
    /// as soon as it finishes: depth is something the user asks for per question, never a mode the app
    /// silently stays in — a sticky "deep" state is how a chat quietly becomes ten times dearer.
    @Published private(set) var deepTurn = false

    /// The model this request actually goes to. Every send path reads this rather than `model`, so the
    /// deep re-run needs no parallel plumbing.
    var requestModel: String { deepTurn ? model(for: .deepAnalysis) : model }

    /// Re-run the last question on the deep-analysis model. Deliberately an action on an ANSWER the user
    /// has already read — not a switch in the composer — so the extra cost is only ever spent when the
    /// quick answer turned out to be too thin, and the user always knows why this one took longer.
    ///
    /// No-op without a configured deep model: re-running the same model would return the same answer
    /// and bill for it twice.
    func regenerateDeeply() {
        guard hasDeepAnalysisModel else { return }
        deepTurn = true
        regenerate()
    }

    /// Take the last question back for editing: drop it and everything after it, and return its text so
    /// the composer can be refilled with it.
    ///
    /// Regenerate answers "same question, try again"; this answers "I asked the wrong thing". Without it
    /// the only way to fix a typo or a badly-phrased question was to retype it and leave the mistake
    /// sitting in the transcript, where it also keeps feeding the history window on every later turn.
    /// Returns nil while a reply is in flight, or when there is no question to reclaim.
    func reclaimLastQuestion() -> String? {
        guard !sending, let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        let question = messages[lastUserIdx].text
        var msgs = messages
        // Same chart cleanup regenerate does: the dropped replies may have hosted chart snapshots, and
        // leaving those behind would strand images with no message to hang on.
        for m in msgs[lastUserIdx...] where m.role == .assistant {
            chartsByMessage[m.id] = nil
            removeChartSnapshot(m.id)
        }
        msgs.removeSubrange(lastUserIdx...)
        messages = msgs
        return question
    }

    /// Regenerate the last reply: drop everything back to (and including) the last user turn, purge any
    /// charts those dropped messages hosted, then resend that same question.
    func regenerate() {
        guard !sending, let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else {
            deepTurn = false   // nothing to resend; don't leave the flag armed for the next question
            return
        }
        let question = messages[lastUserIdx].text
        var msgs = messages
        for m in msgs[lastUserIdx...] where m.role == .assistant {
            chartsByMessage[m.id] = nil
            removeChartSnapshot(m.id)
        }
        msgs.removeSubrange(lastUserIdx...)   // drop the user turn too; send() re-appends it
        messages = msgs
        startSend(question)
    }

    /// Drop a chart snapshot from the active conversation (used when regenerating over it).
    private func removeChartSnapshot(_ id: UUID) {
        guard let cid = activeConversationID,
              let idx = conversations.firstIndex(where: { $0.id == cid }) else { return }
        conversations[idx].charts[id.uuidString] = nil
    }

    /// True when an error is really a task/URL cancellation (a user Stop), not a genuine failure.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    // MARK: Key management

    /// Whether a Keychain key exists AND belongs to the CURRENTLY SELECTED provider (a legacy ownerless
    /// key counts as belonging to any cloud provider, matching `resolvedKey`'s rule below — the two must
    /// never disagree). There is only ever ONE stored key at a time (a single Keychain slot, not one per
    /// provider — #P4 explicitly avoids a multi-provider key architecture), so switching to a provider
    /// that isn't the key's owner correctly reads as "no key here yet", not a stale leftover connection.
    private var storedKeyBelongsToCurrentProvider: Bool {
        guard AIKeyStore.read() != nil else { return false }
        let owner = AIKeyStore.ownerProvider
        if owner == provider.rawValue { return true }
        if owner == nil && provider != .custom { return true }
        return false
    }

    /// True when a key is present in the Keychain **for the currently selected provider**. Ownership-
    /// aware (#P4 4.1): before this, `hasKey` (and thus `isConfigured`) just checked "is any key present
    /// at all" — so switching from a configured provider to a fresh one left `isConfigured` true off the
    /// OLD provider's key, which `resolvedKey` would then correctly refuse to send (owner mismatch),
    /// producing a confusing "looks connected, silently fails" state. Now the two can't disagree.
    var hasKey: Bool { storedKeyBelongsToCurrentProvider }

    /// True once the coach can actually send: a stored key for the cloud providers (and the user hasn't
    /// explicitly disconnected — #P4 4.2/4.3), or, for the Custom (local) provider, a committed base URL
    /// (a key is optional there, as local servers usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : (hasKey && !explicitlyDisconnected) }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`. Deliberately does NOT check
    /// `explicitlyDisconnected` beyond what `isConfigured`/callers already gate on — `resolvedKey` is
    /// only ever reached once a send has been allowed to proceed.
    private var resolvedKey: String? {
        guard storedKeyBelongsToCurrentProvider, let k = AIKeyStore.read() else {
            return provider == .custom ? "" : nil
        }
        return k
    }

    /// Commit the Custom (local) provider once the user has entered a server URL. Optionally stores a
    /// key first if they pasted one. Pulls the server's live model list so the picker isn't empty.
    func connectCustom() {
        let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        clearError()
        customConnected = true
        // Pull the server's model list; if the user hasn't picked one yet, default to the first.
        Task {
            await refreshModels()
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = availableModels.first {
                model = first
            }
        }
    }

    /// Disconnect: stop using the current provider WITHOUT touching the stored key (#P4 4.3 — disconnect
    /// and forgetting a key are different actions; only `clearKey()` deletes anything). For Custom this
    /// un-commits the base URL (kept so reconnecting pre-fills it); for a cloud provider this flips
    /// `explicitlyDisconnected`, so `isConfigured` goes false immediately and consistently (#P4 4.2) while
    /// the Keychain key survives for `setKey`/`reconnect()` to pick back up without re-entering it.
    func disconnect() {
        if provider == .custom {
            customConnected = false
        } else {
            explicitlyDisconnected = true
        }
        objectWillChange.send()
    }

    /// Resume a cloud provider using the key ALREADY in the Keychain, without re-entering it — the
    /// counterpart to `disconnect()` when the user disconnected but never cleared the key. A no-op if
    /// there's no matching key to resume with (the UI only offers this when `hasKey` is already true).
    func reconnect() {
        explicitlyDisconnected = false
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error. If the Keychain write fails the
    /// key is NOT saved, so surface that to the UI instead of silently proceeding (#872).
    func setKey(_ key: String) {
        guard AIKeyStore.save(key, owner: provider.rawValue) else {
            errorText = AICoachError.keySaveFailed.errorDescription
            objectWillChange.send()
            return
        }
        // Saving a (possibly new) key is an implicit reconnect — a user who disconnected, then pastes a
        // fresh key, obviously wants to use it rather than stay marked disconnected underneath (#P4 4.3).
        explicitlyDisconnected = false
        clearError()
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET
        // egresses to the provider the MOMENT a key is saved (IP + request timing + key-validity) — before
        // any send, in an app that is zero-network by default. The picker shows the curated models; the
        // LIVE list is pulled only when the user taps Refresh (an explicit action that is its own
        // consent), or — for OpenRouter, whose tool support is per-model — on the first send, via
        // `ensureOpenRouterCapabilities()`. Local Custom servers still refresh on Connect.
    }

    /// Forget the stored key.
    func clearKey() {
        AIKeyStore.clear()
        objectWillChange.send()
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Test seam (DEBUG only): lets a test stand in for the live `fetchModels` network call so it can
    /// control timing and which provider's ids come back. Production never sets this, so the real path
    /// below is byte-identical in release builds.
    #if DEBUG
    var fetchModelsOverride: ((_ provider: AIProvider, _ key: String) async throws -> [String])?
    /// Test seam for OpenRouter's richer fetch (id list + per-model tool capability), separate from
    /// `fetchModelsOverride` above since that one only carries plain ids.
    var openRouterModelDetailsOverride: ((_ key: String) async throws -> [OpenRouterModel])?
    #endif

    /// OpenRouter-only: `refreshModels()` needs BOTH the id list and per-model tool-support from the
    /// SAME `/models` response — `toolCallingActive` (`CoachTools.swift`) gates P9's tool path per model,
    /// not every model behind OpenRouter can take tool definitions.
    private func fetchOpenRouterModelDetails(key: String) async throws -> [OpenRouterModel] {
        #if DEBUG
        if let override = openRouterModelDetailsOverride { return try await override(key) }
        #endif
        return try await OpenRouterClient().fetchModelDetails(key: key, session: session)
    }

    /// One-shot, before an OpenRouter send: learn which models can take tools, if we don't know yet.
    ///
    /// Without this an OpenRouter user who never taps "Refresh models" has `toolCallingActive == false`
    /// forever — no `propose_plan`, no charts, no memory, and no hint that anything is missing.
    ///
    /// On #288 (don't egress on key-save): that concern was egress the user didn't ask for, at the
    /// moment a key is saved and before any send. This runs *as part of* a send the user just asked
    /// for, to an endpoint we are already talking to on the very same turn — it adds no new surface and
    /// no new party. The result is persisted, so in practice it runs once per install.
    ///
    /// Deliberately silent: it must NEVER write `errorText`. A failed capability probe is not the
    /// user's send failing — the send proceeds on the context path, exactly as it would have anyway.
    private func ensureOpenRouterCapabilities() async {
        guard provider == .openRouter, openRouterToolCapableModels.isEmpty else { return }
        guard let key = resolvedKey, !key.isEmpty else { return }
        guard let details = try? await fetchOpenRouterModelDetails(key: key) else { return }
        // The user can switch providers while this is in flight (#873's concern, same shape): a set
        // fetched for OpenRouter is meaningless if they've moved on, and is only ever consulted for
        // OpenRouter anyway.
        guard provider == .openRouter else { return }
        let capable = Set(details.filter { $0.supportsTools }.map { $0.id })
        guard !capable.isEmpty else { return }
        openRouterToolCapableModels = capable
    }

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        guard let key = resolvedKey else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        clearError()

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            // Carried past the #873 race guard below alongside `ids`, so a mid-flight provider switch
            // discards a stale capability set exactly the same way it already discards stale ids.
            var toolCapable: Set<String>?
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else if capturedProvider == .openRouter {
                let details = try await fetchOpenRouterModelDetails(key: key)
                ids = details.map { $0.id }
                toolCapable = Set(details.filter { $0.supportsTools }.map { $0.id })
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            if capturedProvider == .openRouter {
                let details = try await fetchOpenRouterModelDetails(key: key)
                ids = details.map { $0.id }
                toolCapable = Set(details.filter { $0.supportsTools }.map { $0.id })
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }
            if let toolCapable { openRouterToolCapableModels = toolCapable }

            guard !ids.isEmpty else {
                errorText = AICoachError.decode.errorDescription
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            //
            // "Current selection" only counts when there IS one. The Custom provider's defaultModel is
            // empty by design (the user picks from the server's own list), so `model` is legitimately ""
            // right up until they choose — and inserting that emptiness would make it a selectable entry
            // AND the list's first, which `connectCustom()` then adopts as its default. The request
            // would go out with `"model": ""` and come back a 400 that looks like the user's fault.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            let current = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty && !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
        } catch {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider else { return }
            setError(error)
            return
        }
    }

    // MARK: Sending

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }
        // Catch an unset model here rather than letting it reach the provider: every server answers a
        // `"model": ""` body with an opaque 400 that gives the user nothing to act on.
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = AICoachError.noModel.errorDescription; return
        }

        clearError()
        messages.append(ChatMessage(role: .user, text: trimmed))
        cardSuggestions = []   // the card's follow-up chips belong to the moment after its read (#P11)
        sending = true
        defer { sending = false }

        // Before deciding whether tools are live: on OpenRouter that answer is per-model and we may not
        // know it yet. Silent no-op for every other provider, and after the first successful probe.
        await ensureOpenRouterCapabilities()

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        // In tool-calling mode we send a lean note and let the model FETCH the data it needs via tools,
        // instead of pre-baking the whole summary into the prompt.
        let context = toolCallingActive
            ? toolModeContext
            : (dataConsent ? await buildFullContext() : noConsentNote)
        let wire = wireMessages(context: context)

        // Streaming path when the provider supports it (Anthropic): the reply appears token-by-token in
        // a live-growing assistant bubble. Any tool rounds run inline. Other providers keep the plain
        // single-shot path below, unchanged.
        if let streamer = provider.client as? StreamingToolClient {
            let replyId = UUID()
            let startedAt = Date()
            messages.append(ChatMessage(id: replyId, role: .assistant, text: "", date: startedAt))
            do {
                let reply = try await streamer.streamWithTools(
                    key: key,
                    model: requestModel,
                    systemPrompt: systemPrompt,
                    messages: wire,
                    tools: toolCallingActive ? coachTools : [],
                    runTool: { [weak self] name, input in
                        await self?.runCoachTool(name, input: input) ?? ""
                    },
                    onDelta: { [weak self] delta in self?.appendDelta(delta, to: replyId) },
                    session: session
                )
                // Attach the evidence chain (P6) now that streaming is done — `appendDelta` only
                // accumulated text as it arrived, it never carries `toolsUsed`.
                if let idx = messages.firstIndex(where: { $0.id == replyId }), messages[idx].text.isEmpty {
                    // An empty reply shows "(no reply)" — unless the turn produced a chart, in which case
                    // we drop the blank bubble and let the chart (flushed below) stand on its own.
                    if pendingCharts.isEmpty {
                        messages[idx] = ChatMessage(id: replyId, role: .assistant, text: "(no reply)",
                                                    date: startedAt, toolsUsed: reply.toolsUsed)
                    } else {
                        messages.remove(at: idx)
                    }
                } else if let idx = messages.firstIndex(where: { $0.id == replyId }), !reply.toolsUsed.isEmpty {
                    messages[idx] = ChatMessage(id: replyId, role: .assistant, text: messages[idx].text,
                                                date: startedAt, toolsUsed: reply.toolsUsed)
                }
                flushPendingCharts()
            } catch let e as AICoachError {
                removeAssistantIfEmpty(replyId); discardPendingCharts(); setError(e)
            } catch {
                // A user-initiated Stop cancels the task; keep whatever streamed so far, show no error.
                if Self.isCancellation(error) {
                    flushPendingCharts()
                } else {
                    removeAssistantIfEmpty(replyId); discardPendingCharts()
                    setError(error)
                }
            }
            return
        }

        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: .assistant, text: clean.isEmpty ? "(no reply)" : clean,
                                        toolsUsed: reply.toolsUsed))
            flushPendingCharts()
        } catch let e as AICoachError {
            discardPendingCharts(); setError(e)
        } catch {
            discardPendingCharts()
            if !Self.isCancellation(error) {
                setError(error)
            }
        }
    }

    /// Append a streamed text delta to the in-flight assistant message (matched by id). `ChatMessage.text`
    /// is immutable, so we replace the element keeping the same id — SwiftUI updates the row in place.
    private func appendDelta(_ delta: String, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx] = ChatMessage(id: id, role: .assistant, text: messages[idx].text + delta)
    }

    /// Drop the streaming placeholder if it never received any text — so a failed request leaves no empty
    /// assistant bubble behind, only the surfaced `errorText`.
    private func removeAssistantIfEmpty(_ id: UUID) {
        if let idx = messages.firstIndex(where: { $0.id == id }), messages[idx].text.isEmpty {
            messages.remove(at: idx)
        }
    }

    // MARK: - Chart artifacts (plot_metric tool)

    /// Charts the coach asked to draw, keyed by the transcript message that hosts them. `CoachView`
    /// renders a native chart for any assistant message whose id is present here. Published so the UI
    /// updates when a chart lands.
    @Published var chartsByMessage: [UUID: CoachChartArtifact] = [:]

    /// Charts requested via the `plot_metric` tool during the current turn, flushed into the transcript
    /// once the reply is done so they appear BELOW the coach's explanation rather than mid-stream.
    private var pendingCharts: [CoachChartArtifact] = []

    /// Handle a `plot_metric` tool call: build the chart and queue it, returning a text confirmation the
    /// model can reference. Returns a "no data" note (never a fabricated chart) when the metric is empty.
    func handlePlotMetric(metric: String, days: Int) async -> String {
        guard let art = await chartArtifact(metric: metric, days: days) else {
            return "No data available to plot \"\(metric)\"."
        }
        pendingCharts.append(art)
        return "Displayed a chart of \(art.title) over the last \(art.points.count) days for the user."
    }

    /// Append one empty assistant message per queued chart (the id links it to `chartsByMessage`), then
    /// clear the queue. Called after a reply completes so charts sit under the text. The chart is also
    /// snapshotted into the active conversation so it survives a relaunch.
    func flushPendingCharts() {
        for art in pendingCharts {
            let id = UUID()
            messages.append(ChatMessage(id: id, role: .assistant, text: ""))
            chartsByMessage[id] = art
            // Re-find the active conversation AFTER the append: writing `messages` re-sorts the list, so
            // any index captured earlier would be stale.
            if let cid = activeConversationID,
               let idx = conversations.firstIndex(where: { $0.id == cid }) {
                conversations[idx].charts[id.uuidString] = CoachChartSnapshot(art)
            }
        }
        pendingCharts.removeAll()
    }

    /// Discard any queued charts (used when a turn errors out).
    func discardPendingCharts() { pendingCharts.removeAll() }

    /// Build a chart artifact from the user's own daily metrics. Reads the private store, so it lives on
    /// the engine rather than in the tool extension. Returns nil for too little data. The five hand-named
    /// metrics below read straight off `repo.days` (no store hit); anything else falls through to any
    /// metric key this user actually has data for (`Repository.availableKeys`/`series`), so `plot_metric`
    /// isn't limited to a hardcoded list of five.
    private func chartArtifact(metric rawMetric: String, days: Int) async -> CoachChartArtifact? {
        let n = max(7, min(days, 180))
        let recent = Array(repo.days.suffix(n))

        func series(_ extract: (DailyMetric) -> Double?) -> [TrendPoint] {
            recent.compactMap { d in
                guard let v = extract(d), let date = Self.parseDay(d.day) else { return nil }
                return TrendPoint(date: date, value: v)
            }
        }

        let title: String
        let points: [TrendPoint]
        let range: ClosedRange<Double>
        let kind: CoachChartArtifact.Kind

        switch rawMetric.lowercased() {
        case "charge", "recovery", "readiness":
            title = "Charge (recovery)"; points = series { $0.recovery }; range = 0...100; kind = .charge
        case "effort", "strain":
            title = "Effort (strain)"; points = series { $0.strain }; range = 0...21; kind = .effort
        case "hrv":
            title = "HRV"; points = series { $0.avgHrv }; kind = .hrv
            range = Self.paddedRange(points.map(\.value), pad: 5)
        case "rhr", "resting", "restinghr":
            title = "Resting HR"; points = series { $0.restingHr.map(Double.init) }; kind = .rhr
            range = Self.paddedRange(points.map(\.value), pad: 5)
        case "sleep", "rest":
            title = "Sleep"; points = series { $0.totalSleepMin.map { $0 / 60 } }; range = 0...12; kind = .sleep
        default:
            guard await repo.availableKeys(source: Repository.whoopSource).contains(rawMetric) else { return nil }
            let rows = await repo.series(key: rawMetric, source: Repository.whoopSource, days: n)
            title = Self.humanizeMetricKey(rawMetric)
            points = rows.compactMap { row in Self.parseDay(row.day).map { TrendPoint(date: $0, value: row.value) } }
            let vals = points.map(\.value)
            let span = (vals.max() ?? 0) - (vals.min() ?? 0)
            range = Self.paddedRange(vals, pad: max(span * 0.1, 0.5))
            kind = .other
        }

        guard points.count >= 2 else { return nil }
        return CoachChartArtifact(title: title, points: points, valueRange: range, kind: kind)
    }

    /// "sleep_performance" → "Sleep Performance", for a chart title built from an arbitrary metric key
    /// the user has data for but that isn't one of the five hand-named metrics above.
    static func humanizeMetricKey(_ key: String) -> String {
        key.split(separator: "_")
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A y-range padded around the data's min/max, guaranteeing lower < upper so the chart never gets a
    /// degenerate domain (used for HRV / RHR where a fixed 0–100 scale would be useless).
    private static func paddedRange(_ vals: [Double], pad: Double) -> ClosedRange<Double> {
        guard let lo = vals.min(), let hi = vals.max() else { return 0...100 }
        let a = lo - pad
        let b = hi + pad
        return a < b ? a...b : a...(a + 1)
    }

    /// Parse a "yyyy-MM-dd" day key (UTC) into a Date for charting.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func parseDay(_ s: String) -> Date? { dayFormatter.date(from: s) }

    // MARK: - Conversational logging + deep-data tools (NOOP AI)

    /// LOCAL "yyyy-MM-dd" formatter — journal/lab entries key on the user's local day (unlike the UTC
    /// chart parser above).
    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A model-supplied day string, validated; anything malformed/absent falls back to today (local).
    private static func normalizedDay(_ raw: String?) -> String {
        if let raw, raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           localDayFormatter.date(from: raw) != nil {
            return raw
        }
        return localDayFormatter.string(from: Date())
    }

    /// `log_caffeine`: write into the SAME shared store the Caffeine card observes, so the entry shows
    /// up in the UI immediately. mg stays optional (the store clamps garbage itself).
    func logCaffeineTool(mg: Double?, minutesAgo: Int) -> String {
        let mins = max(0, min(minutesAgo, 24 * 60))
        let at = Date().addingTimeInterval(-Double(mins) * 60)
        CaffeineLogStore.shared.log(at: at, mg: mg)
        let time = DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short)
        let amount = mg.map { "\(Int($0.rounded())) mg" } ?? "an unspecified amount of"
        return "Logged \(amount) caffeine at \(time). It appears in the app's Caffeine card, where the user can correct or remove it."
    }

    /// `log_journal`: persist a yes/no or numeric behaviour for a day via the repository's journal
    /// store (SQLite), and register the behaviour in the catalog so it appears in the Journal UI
    /// (`addCustom` de-duplicates, so an existing question is untouched).
    func logJournalTool(behavior: String, answeredYes: Bool?, value: Double?, day rawDay: String?) async -> String {
        let name = behavior.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "No behaviour name given — nothing was logged." }
        let day = Self.normalizedDay(rawDay)
        if let value, value.isFinite {
            JournalCatalogStore().addCustom(name, kind: .numeric(unitLabel: nil))
            await repo.saveJournalNumeric(day: day, question: name, value: value)
            return "Logged \(name) = \(value) for \(day) in the user's journal."
        }
        let yes = answeredYes ?? true
        JournalCatalogStore().addCustom(name, kind: .bool)
        await repo.saveJournalAnswer(day: day, question: name, answeredYes: yes)
        return "Logged \(name): \(yes ? "yes" : "no") for \(day) in the user's journal."
    }

    /// `log_lab_marker`: upsert one Lab Book row through the shared store (the same path the Lab Book
    /// UI and CSV import use), then refresh so it projects into Compare/Explore/Coach.
    func logLabMarkerTool(marker: String, value: Double?, unit: String, day rawDay: String?) async -> String {
        let name = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let value, value.isFinite else {
            return "Need a marker name and a numeric value — nothing was logged."
        }
        guard let store = await repo.storeHandle() else { return "Couldn't open the local store." }
        let day = Self.normalizedDay(rawDay)
        let epoch = LabBookFormat.noonEpoch(day)
        // Stable-ish key: a lowercase slug of the name, so repeat logs of the same marker line up
        // into one series in the Lab Book / Explore.
        let key = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let row = LabMarkerRow(
            id: "\(key)-\(epoch)-\(UUID().uuidString.prefix(8))",
            deviceId: repo.deviceId,
            markerKey: key,
            category: LabMarkerCategory.other.rawValue,
            day: day,
            takenAt: epoch,
            value: value,
            valueText: nil,
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
            source: "coach-chat",
            note: nil,
            referenceText: nil
        )
        do {
            _ = try await store.upsertLabMarkers([row])
            await repo.refresh()
            let unitPart = row.unit.isEmpty ? "" : " \(row.unit)"
            return "Logged \(name): \(value)\(unitPart) for \(day) in the user's Lab Book."
        } catch {
            return "Couldn't save the marker: \(error.localizedDescription)"
        }
    }

    /// `get_my_logs`: read back what the user has LOGGED, by kind. Closes the write-without-read
    /// asymmetry — the coach could log a coffee/journal/marker but never recall them — with ONE tool
    /// instead of five. Each kind reads the SAME store the corresponding log/UI writes. An unknown kind
    /// returns recoverable text (never throws), and `lab` refuses without the second on-device-signals
    /// opt-in, mirroring `get_personal_patterns`. Never a bare empty string: a blank tool result is what
    /// makes a model hallucinate, so an empty log says so in words.
    func myLogsTool(kind: String, days: Int) async -> String {
        switch kind.lowercased() {
        case "caffeine":
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let recent = CaffeineLogStore.shared.intakes.filter { $0.at >= cutoff }
            let estimate = CaffeineLogStore.shared.estimate()
            guard !recent.isEmpty else { return "No caffeine logged in the last \(days) days." }
            var lines = ["CAFFEINE LOG (newest first, last \(days) days):"]
            for i in recent.prefix(30) {
                let when = DateFormatter.localizedString(from: i.at, dateStyle: .short, timeStyle: .short)
                let amount = i.mg.map { "\(Int($0.rounded())) mg" } ?? "unspecified amount"
                lines.append("  • \(when): \(amount)")
            }
            if estimate.hasActive {
                let mg = estimate.totalRemainingMg.map { " (~\(Int($0.rounded())) mg)" } ?? ""
                lines.append("Still active now: \(estimate.activeIntakeCount) intake(s)\(mg).")
            } else {
                lines.append("Nothing estimated still active right now.")
            }
            return lines.joined(separator: "\n")

        case "journal":
            let cutoffDay = Repository.localDayKey(Date().addingTimeInterval(-Double(days) * 86_400))
            let entries = (await repo.journalEntries()).filter { $0.day >= cutoffDay }
                .sorted { $0.day > $1.day }
            guard !entries.isEmpty else { return "No journal entries in the last \(days) days." }
            var lines = ["JOURNAL LOG (newest first, last \(days) days):"]
            for e in entries.prefix(40) {
                let val = e.numericValue.map { " = \($0)" } ?? (e.answeredYes ? ": yes" : ": no")
                lines.append("  • \(e.day) — \(e.question)\(val)")
            }
            return lines.joined(separator: "\n")

        case "lab":
            guard includeOnDeviceSignals else {
                return "The user hasn't shared their Lab Book, so this isn't available."
            }
            guard let store = await repo.storeHandle() else { return "Couldn't open the local store." }
            var lines: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                for (key, kRows) in Dictionary(grouping: rows, by: { $0.markerKey }) {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key)) \(latest.unit)" }
                        ?? latest.valueText ?? "—"
                    lines.append("  • \(name): \(value) (\(latest.day))")
                }
            }
            guard !lines.isEmpty else { return "No Lab Book markers logged yet." }
            return "LAB BOOK (latest per marker — the user's own logged health numbers, not medical "
                + "advice):\n" + lines.joined(separator: "\n")

        case "hydration":
            let history = await repo.hydrationHistory(days: days)
            let logged = history.filter { $0.value > 0 }
            guard !logged.isEmpty else { return "No hydration logged in the last \(days) days." }
            let goal = repo.hydrationGoalML(profileSex: ProfileStore().sex)
            var lines = ["HYDRATION LOG (ml per day, today's goal \(goal) ml, last \(days) days):"]
            for (day, ml) in history.reversed() where ml > 0 {
                lines.append("  • \(day): \(Int(ml.rounded())) ml")
            }
            return lines.joined(separator: "\n")

        case "mood":
            let cutoffDay = Repository.localDayKey(Date().addingTimeInterval(-Double(days) * 86_400))
            let series = (await repo.moodSeries()).filter { $0.day >= cutoffDay }
            guard !series.isEmpty else { return "No mood check-ins in the last \(days) days." }
            var lines = ["MOOD LOG (daily 1–5 check-in, newest first, last \(days) days):"]
            for (day, value) in series.sorted(by: { $0.day > $1.day }).prefix(40) {
                let v = Int(value.rounded())
                lines.append("  • \(day): \(v)/5 (\(MoodStore.label(for: v)))")
            }
            return lines.joined(separator: "\n")

        default:
            return "Unknown log kind \"\(kind)\". Choose one of: caffeine, journal, lab, hydration, mood."
        }
    }

    /// `get_zone_minutes`: time-in-zone (Zone 1–5) minutes over the user's recent workout HR, so a "did
    /// I hit Zone 2?" question — and `propose_plan`'s own Zone-2 prescriptions — can be checked against
    /// what was actually done. Wraps `Repository.workoutZoneMinutes` (HRZones math), aged from the
    /// profile. Nil (no HR/workout data) returns a plain "no zone data" line, never an empty string.
    func zoneMinutesTool(days: Int) async -> String {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - days * 86_400
        let age = ProfileStore().age
        guard let minutes = await repo.workoutZoneMinutes(from: from, to: now, age: age),
              minutes.count == 5 else {
            return "No workout heart-rate data in the last \(days) days to compute zone minutes."
        }
        var lines = ["TIME IN ZONE (minutes, last \(days) days — from workout HR):"]
        for (i, m) in minutes.enumerated() {
            lines.append(String(format: "  Zone %d: %.0f min", i + 1, m))
        }
        return lines.joined(separator: "\n")
    }

    /// `get_sleep_detail`: per-night stages/efficiency from the daily roll-up plus the rolling
    /// 14-night sleep-debt ledger (`SleepDebt.ledger`). Summary text only, never raw samples.
    func sleepDetailTool(nights: Int) async -> String {
        let n = max(1, min(nights, 14))
        let all = repo.days
        let recent = Array(all.suffix(n))
        guard !recent.isEmpty else { return "No sleep data recorded yet." }

        // Stage minutes (`SleepStager.hypnogramMetrics`) stay out of this tool deliberately — bed/wake
        // consistency is the most actionable thing a coach has on sleep, not a third data source
        // bloating every call.
        let now = Int(Date().timeIntervalSince1970)
        let sessions = await repo.sleepSessions(from: now - (n + 2) * 86_400, to: now + 86_400, limit: n + 5)
        let habitual = await repo.habitualMidsleepSec()
        var text = Self.formatSleepDetail(recentDays: recent, sessions: sessions, habitualMidsleepSec: habitual)

        // Rolling sleep-debt ledger over the last 30 nights (14-night window inside the engine).
        let ledger = SleepDebt.ledger(series: all.suffix(30).map { ($0.day, $0.totalSleepMin) })
        if !ledger.nights.isEmpty {
            let bal = ledger.balanceMin / 60
            let need = ledger.needMin / 60
            text += "\n\n" + String(format: "Sleep debt (rolling %d nights vs a %.1fh need): %+.1fh %@",
                                    ledger.nights.count, need, bal,
                                    bal < 0 ? "(deficit — behind on sleep)" : "(surplus)")
        }
        return text
    }

    /// Pure formatter for `sleepDetailTool`: bed/wake times (keyed by wake-day exactly as
    /// `Repository.mergeSleep.endDay` does, so a night's times line up with its `DailyMetric` row) plus a
    /// comparison of last night's sleep midpoint to the user's LEARNED habitual midsleep
    /// (`repo.habitualMidsleepSec()` — the same value the Sleep tab's main-night picker uses).
    /// Consistency is the lever a coach can actually act on; only surfaced once there's enough history to
    /// have learned a habit, and only when the shift is large enough to be worth a line. Kept free of
    /// `repo`/store reads so it's unit-testable without a database.
    nonisolated static func formatSleepDetail(recentDays: [DailyMetric], sessions: [CachedSleepSession],
                                              habitualMidsleepSec: Int?) -> String {
        guard !recentDays.isEmpty else { return "No sleep data recorded yet." }

        func wakeDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        let sessionByDay = Dictionary(sessions.map { (wakeDay($0), $0) }, uniquingKeysWith: { _, latest in latest })
        let clockFmt = DateFormatter()
        clockFmt.dateFormat = "HH:mm"
        clockFmt.timeZone = .current
        func clock(_ ts: Int) -> String { clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }

        var lines = ["SLEEP DETAIL (newest first) — bed→wake, asleep(h), efficiency(%), deep/REM/light(min), disturbances, RHR, HRV:"]
        for d in recentDays.reversed() {
            var parts = ["  \(d.day):"]
            if let s = sessionByDay[d.day] {
                parts.append("\(clock(s.effectiveStartTs))→\(clock(s.endTs))")
            } else {
                parts.append("bed/wake —")
            }
            parts.append("slept " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
            parts.append("eff " + (d.efficiency.map { "\(Int($0.rounded()))%" } ?? "—"))
            parts.append("deep " + (d.deepMin.map { "\(Int($0.rounded()))m" } ?? "—"))
            parts.append("REM " + (d.remMin.map { "\(Int($0.rounded()))m" } ?? "—"))
            parts.append("light " + (d.lightMin.map { "\(Int($0.rounded()))m" } ?? "—"))
            parts.append("disturbances " + (d.disturbances.map { "\($0)" } ?? "—"))
            parts.append("RHR " + (d.restingHr.map { "\($0)" } ?? "—"))
            parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
            lines.append(parts.joined(separator: ", "))
        }

        if let habitual = habitualMidsleepSec, let lastNight = sessions.max(by: { $0.endTs < $1.endTs }) {
            let offsetSec = TimeZone.current.secondsFromGMT(
                for: Date(timeIntervalSince1970: TimeInterval(lastNight.endTs)))
            let secondsPerDay = 86_400
            let mid = (lastNight.effectiveStartTs + lastNight.endTs) / 2
            let localMid = (((mid + offsetSec) % secondsPerDay) + secondsPerDay) % secondsPerDay
            var diff = localMid - habitual
            if diff > secondsPerDay / 2 { diff -= secondsPerDay }
            if diff < -secondsPerDay / 2 { diff += secondsPerDay }
            let deltaMin = abs(diff) / 60
            if deltaMin >= 20 {
                lines.append("")
                lines.append("Last night's sleep midpoint was ~\(deltaMin) min \(diff >= 0 ? "later" : "earlier") "
                             + "than the user's usual, learned midsleep.")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// `get_range_report`: the same per-metric stats + headlines the Trends report screen shows,
    /// over an arbitrary 7–365-day window (reuses `TrendsReportData.metricMaps` + `RangeReportEngine`).
    func rangeReportTool(days: Int) async -> String {
        let n = max(7, min(days, 365))
        let window = Array(repo.days.suffix(n))
        guard window.count >= 3, let first = window.first, let last = window.last else {
            return "Not enough recorded days for a range report yet."
        }
        let stress = await repo.series(key: "stress", source: "my-whoop", days: n)
        let stressByDay = Dictionary(stress.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        let report = RangeReportEngine.build(
            metrics: TrendsReportData.metricMaps(from: window, stressByDay: stressByDay),
            start: first.day, end: last.day)
        guard !report.isEmpty else { return "No data in that range." }

        var lines = ["RANGE REPORT \(report.start) → \(report.end) (\(report.totalDays) days):"]
        if !report.headlines.isEmpty {
            lines.append("Headlines:")
            for h in report.headlines { lines.append("  • \(h)") }
        }
        lines.append("Per metric — mean, first→second half, trend, latest:")
        for s in report.metrics {
            let fmt: (Double) -> String = s.metric.usesOneDecimal
                ? { String(format: "%.1f", $0) } : { "\(Int($0.rounded()))" }
            let unit = s.metric.unit.isEmpty ? "" : " \(s.metric.unit)"
            lines.append("  \(s.metric.label): mean \(fmt(s.mean))\(unit), "
                         + "\(fmt(s.firstHalfMean))→\(fmt(s.secondHalfMean)) (\(s.trend.rawValue)), "
                         + "latest \(fmt(s.latest.value)) on \(s.latest.day) (n=\(s.n))")
        }
        return lines.joined(separator: "\n")
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    /// Start a fresh "Today's brief" if the active conversation doesn't have one for TODAY yet, and no
    /// brief has been generated anywhere today (`ai.lastBriefDay`, the logical day, rolls 04:00 — same
    /// semantics as the rest of the app). Fixes the old per-conversation-only gate: reopening a
    /// conversation whose last message predates today now gets caught up with a fresh brief instead of
    /// silently showing Monday's brief on Friday, while two conversations opened the same day don't each
    /// get their own.
    func startBriefIfNeeded() async {
        let today = Repository.logicalDayKey(Date())
        guard UserDefaults.standard.string(forKey: Self.lastBriefDayKey) != today else { return }
        if let last = messages.last, Repository.logicalDayKey(last.date) == today { return }
        // Each day's brief lands in its OWN thread (#R8) so yesterday's can be archived out of the main
        // history list without disturbing the user's real chats. The gate above guarantees the active
        // thread is stale or empty here, so switching away from it is never disruptive.
        startBriefThread()
        await runBriefCancellable()
        archiveStaleAutoThreads()
    }

    /// Give the day's brief its own thread (#R8). Reuse the active conversation only when it's already
    /// empty — otherwise the brief would append onto the user's last chat and could never be archived
    /// on its own. Mirrors `newConversation`'s summarise-on-leave and empty-reuse rules.
    private func startBriefThread() {
        if let cur = activeConversation, cur.messages.isEmpty { return }
        if let leaving = activeConversationID { maybeSummarize(leaving) }
        let fresh = CoachConversation(title: String(localized: "Today's brief"))
        conversations.insert(fresh, at: 0)
        activeConversationID = fresh.id
        chartsByMessage = [:]
        clearError()
    }

    /// Day-boundary sweep (#R8): archive auto-only threads — a brief or nudge the user never replied to —
    /// whose last activity predates today, moving them into the history's Archived section. Never touches
    /// the active thread, a thread the user actually took a turn in, or one already archived. Purely
    /// additive: nothing is deleted, and an archived thread stays findable and restorable.
    func archiveStaleAutoThreads() {
        let today = Repository.logicalDayKey(Date())
        for idx in conversations.indices {
            let c = conversations[idx]
            guard !c.archived, c.id != activeConversationID, c.isAutoOnly,
                  let last = c.messages.last,
                  Repository.logicalDayKey(last.date) != today else { continue }
            conversations[idx].archived = true
        }
    }

    /// Run the brief as `sendTask` so the composer's Stop button actually cancels it — previously the
    /// button rendered during a brief but cancelled nothing. A cancelled brief doesn't stamp the day,
    /// so it is retried on the next open.
    private func runBriefCancellable() async {
        guard !sending else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.generateBrief()
        }
        sendTask = task
        await task.value
        if sendTask == task { sendTask = nil }
    }

    /// The morning brief's instruction, split out so it's testable and so part (2) can require a
    /// structured proposal — but ONLY when the tool to make one is actually on the wire. When it isn't
    /// (a non-tool provider, consent off), it mirrors W1's honesty: name the session, don't pretend to
    /// have recorded it. Part (2) is where "the text should work that way too" lives — the brief names
    /// today's session concretely and says it's waiting on a yes (WHOOP's Daily-Outlook tone, NOOP's
    /// consent model).
    ///
    /// The two branches differ in their OPENING PREMISE, not just part (2). "Based on the data above" is
    /// only true on the non-tool path, where `buildFullContext()` really did put charge/HRV/rest/readiness
    /// in the message. On the tool path the brief runs on `toolModeContext` — a short note plus the plan
    /// block, no numbers at all — so a brief that opened the same way for both was asking the model to
    /// cite figures it had never been given. The tool-mode premise instead requires fetching them first.
    static func briefInstruction(toolsActive: Bool) -> String {
        guard toolsActive else {
            return """
            Based on the data above, give me TODAY'S coaching brief — kept tight, no preamble, three \
            short parts: \
            (1) my readiness in one line, citing charge, HRV and rest; \
            (2) exactly what to do today — the activity, its intensity, and a rough duration — and what \
            to avoid. If my readiness is low, make it the easy/short option (or rest) and say so plainly. \
            You cannot record it for me, so close by telling me to add it in Your plan if I want it; \
            (3) one specific thing to improve my charge. Be punchy and motivating — not long.
            """
        }
        return """
        You have not been given any of my numbers yet. Before you write anything, call get_readiness and \
        get_biometric_summary; call get_charge_drivers too if my Charge is notably high or low, and \
        get_sleep_detail if sleep is the story. Once you have real numbers, give me TODAY'S coaching brief \
        — kept tight, no preamble, three short parts: \
        (1) my readiness in one line, citing the charge, HRV and rest you just fetched; \
        (2) exactly what to do today — the activity, its intensity, and a rough duration. If my readiness \
        is low, make it the easy/short option (or rest) and say so. Then record THAT session with \
        propose_plan for today's date so it shows on the Today screen for me to accept, change or \
        decline. Propose exactly ONE session for today. It is a suggestion, not a booking — never \
        describe it as scheduled. Anything already awaiting my decision or already committed is recorded; \
        do not propose it again; \
        (3) one specific thing to improve my charge, grounded in what get_charge_drivers showed. Be punchy \
        and motivating — not long.
        """
    }

    /// The check-in's instruction — a SIBLING of `briefInstruction`, same two-branch split, but a
    /// different act. A brief looks forward ("here's today's plan"); a check-in looks back ("how did the
    /// last one go?"). It opens on what the user actually DID and LOGGED, asks about the reason already
    /// in the data rather than inventing one, and stops at a single small adjustment — a conversation,
    /// not a second briefing. The skip-reason tone is `CoachPlanStore`'s, verbatim: a skip is
    /// information, never laziness.
    static func checkInInstruction(toolsActive: Bool) -> String {
        guard toolsActive else {
            return """
            This is a check-in, not a fresh brief. Using the plan-adherence and logs above, reply in two \
            or three short sentences: \
            (1) reflect back the ONE thing that stands out in what I actually did — a session hit, or one \
            skipped (the skip reason is right there; read it as information, NEVER as laziness), or a log \
            worth noting; \
            (2) ask ONE genuine question about it, grounded in that reason; \
            (3) offer AT MOST ONE small adjustment, and only if it clearly helps. No full plan, no \
            lecture — a conversation, not a briefing.
            """
        }
        return """
        This is a check-in, not a fresh brief. Call get_plan_adherence and get_my_logs to see what I \
        actually did and logged since we last spoke. Then reply in two or three short sentences: \
        (1) reflect back the ONE thing that stands out — a session hit, or one skipped (the skip reason \
        is in the data; read it as information, NEVER as laziness), or a log worth noting; \
        (2) ask ONE genuine question about it, grounded in that reason; \
        (3) offer AT MOST ONE small adjustment, and only if it clearly helps. No full plan, no lecture — \
        a conversation, not a briefing.
        """
    }

    /// Shared brief generation: build today's context and ask the provider for the three-part brief.
    /// Gated on a key + data consent; `!sending` prevents overlapping a brief with an in-flight message.
    private func generateBrief() async {
        guard isConfigured, dataConsent, !sending else { return }
        guard let key = resolvedKey else { return }
        clearError()
        sending = true
        defer { sending = false }

        // Same reason as in `send()`: on OpenRouter, whether tools are live is a per-model fact we may
        // not know yet, and the brief is exactly where a missing propose_plan hurts most.
        await ensureOpenRouterCapabilities()

        let context = toolCallingActive ? toolModeContext : await buildFullContext()
        // Empty context (tool path, nothing pending) → the instruction alone, no dangling "---" separator.
        let instruction = Self.briefInstruction(toolsActive: toolCallingActive)
        let briefContent = context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? instruction
            : context + "\n\n---\n\n" + instruction
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, briefContent)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: "Today's brief\n\n" + clean,
                                            toolsUsed: reply.toolsUsed, origin: .brief))
                // Stamp only on genuine success, so a network failure doesn't burn the day's slot — a
                // retry (reopening the conversation after a day boundary) can still land one.
                UserDefaults.standard.set(Repository.logicalDayKey(Date()), forKey: Self.lastBriefDayKey)
            }
        } catch let e as AICoachError {
            setError(e)
        } catch {
            // A user-initiated Stop is not an error — and must not stamp the day (see above), so the
            // brief comes back on the next open instead of silently vanishing until tomorrow.
            if !Self.isCancellation(error) {
                setError(error)
            }
        }
    }

    /// Generate a check-in once per logical day (its OWN lock, independent of the brief's — see
    /// `lastCheckInDayKey`). Backs the daily check-in notification's tap. A failed run doesn't stamp the
    /// day, so the next tap retries.
    func checkInIfNeeded() async {
        let today = Repository.logicalDayKey(Date())
        guard UserDefaults.standard.string(forKey: Self.lastCheckInDayKey) != today else { return }
        await runCheckInCancellable()
    }

    /// Cancellable check-in runner, mirroring `runBriefCancellable` so the composer's Stop button
    /// actually cancels it.
    private func runCheckInCancellable() async {
        guard !sending else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.generateCheckIn()
        }
        sendTask = task
        await task.value
        if sendTask == task { sendTask = nil }
    }

    /// Shared check-in generation. Unlike `generateBrief` — which sends a single synthetic user turn with
    /// no transcript — a check-in is a CONTINUATION, so it routes with the windowed history behind it and
    /// relevant memory folded in, exactly like a normal `send()` turn. Stamps `lastCheckInDayKey` only on
    /// success.
    private func generateCheckIn() async {
        guard isConfigured, dataConsent, !sending else { return }
        guard let key = resolvedKey else { return }
        clearError()
        sending = true
        defer { sending = false }

        await ensureOpenRouterCapabilities()

        let context = toolCallingActive ? toolModeContext : await buildFullContext()
        let instruction = Self.checkInInstruction(toolsActive: toolCallingActive)
        // Fold relevant memory in like a normal turn (wireMessages does the same for send()).
        let relevant = CoachMemory.shared.relevantBlock(for: instruction, limit: 8)
        let preamble = [context, relevant]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let trailer = preamble.isEmpty ? instruction : preamble + "\n\n---\n\n" + instruction
        // History (windowed) + the check-in as the trailing user turn, kept role-alternating.
        let history = Self.wirePairs(from: windowedMessages(), context: "")
        let wire = Self.appendTrailingUserTurn(history, content: trailer)
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: "Check-in\n\n" + clean,
                                            toolsUsed: reply.toolsUsed, origin: .checkIn))
                UserDefaults.standard.set(Repository.logicalDayKey(Date()), forKey: Self.lastCheckInDayKey)
            }
        } catch let e as AICoachError {
            setError(e)
        } catch {
            if !Self.isCancellation(error) {
                setError(error)
            }
        }
    }

    // MARK: - Proactive coaching (#P10) + weekly review

    /// The instruction for an UNPROMPTED nudge, seeded by a detected signal. Milestone = a short, warm
    /// congratulation; setback = a short, kind "let's make this realistic" — never a scolding, since a
    /// skip is information, not laziness (the store's tone, held here too).
    static func proactiveNudgeInstruction(for signal: ProactiveSignal) -> String {
        switch signal.category {
        case .milestone:
            return """
            The user just hit a real milestone: \(signal.seed). Send ONE short, warm message — \
            congratulate them specifically on that in a sentence or two, then either ask one light \
            question or offer one small next step. Not over-the-top, no bullet lists, no lecture.
            """
        case .setback:
            return """
            The user has fallen behind: \(signal.seed). Send ONE short, kind message. A skip is \
            information, NEVER laziness — do not scold. Acknowledge it plainly, ask what's getting in the \
            way, and offer ONE concrete way to make the plan more realistic (smaller, less often, or a \
            different form). Keep it to a few sentences.
            """
        }
    }

    /// The weekly-review instruction — a short coach's word on the week, not a report (#P10 13.2). Same
    /// two-branch tool/non-tool split as the brief/check-in.
    ///
    /// #P15 (16.2): explicitly directs `get_zone_minutes` when a prescribed Moderate/Hard session is in
    /// the week — the intent alone ("Moderate") says what was PLANNED, not what actually happened at the
    /// heart-rate level, and `propose_plan`'s own Zone-2 prescriptions on low-readiness days are exactly
    /// the kind of thing that quietly drifts. Without this the review can only ever comment on whether a
    /// session happened, never on whether it was trained at the right intensity — an oberflächlicher
    /// (superficial) read the catalog explicitly calls out.
    static func weeklyReviewInstruction(toolsActive: Bool) -> String {
        guard toolsActive else {
            return """
            It's the weekly review. Using the range and adherence data above, in a short paragraph or \
            two: what went well, where I was consistent, where it slipped (skip reasons are information, \
            never laziness), and ONE thing to adjust next week. Keep it short — a coach's weekly word.
            """
        }
        return """
        It's the weekly review. Call get_range_report and get_plan_adherence to see the week. If a \
        Moderate or Hard session was completed, or a low-readiness day called for Zone 2, also call \
        get_zone_minutes — don't assume the prescribed intensity was hit just because the session is \
        marked done. Then, in a short paragraph or two: what went well, where I was consistent, where it \
        slipped (read any skip reasons as information, never laziness), and ONE thing to adjust next \
        week — grounded in the trend across the week, not one day. No long analysis — a coach's weekly \
        word, not a report.
        """
    }

    /// Fire a proactive nudge at most once per logical day, only when the level allows AND the detector
    /// finds a real signal in the plan history (10.2/10.3/10.4). Wired to Coach opening, alongside the
    /// brief — but signals are rare (a streak, or a run of skips), so this stays quiet on ordinary days.
    func runProactiveNudgeIfNeeded() async {
        guard proactiveLevel != .off, isConfigured, dataConsent, !sending else { return }
        let today = Repository.logicalDayKey(Date())
        guard UserDefaults.standard.string(forKey: Self.lastProactiveDayKey) != today else { return }
        guard let signal = ProactiveCoach.detect(proposals: CoachPlanStore.shared.proposals,
                                                  goals: CoachGoalStore.shared.goals,
                                                  level: proactiveLevel) else { return }
        let prefix = signal.category == .milestone ? "Nice work" : "A quick nudge"
        await runSeededTurnCancellable(
            instruction: Self.proactiveNudgeInstruction(for: signal),
            prefix: prefix, stampKey: Self.lastProactiveDayKey, origin: .nudge)
    }

    /// The instruction for a goal-expiry look-back. Deliberately not a verdict template: the coach is
    /// told to state what the data shows and ASK what the person wants to do next, because "you failed"
    /// is both unhelpful and often wrong — a missed date can mean illness, travel or a goal that was
    /// never realistic, and the app can't tell which.
    static func goalReviewInstruction(for goal: CoachGoal) -> String {
        """
        The user's goal "\(goal.title)" reached its target date and neither of you has closed it out. \
        Look back on it now, unprompted. Use the tools to check what actually happened over that period \
        rather than guessing. Say plainly whether it was reached, missed, or can't be judged from the \
        data — "can't be judged" is an honest answer and often the right one. Do NOT congratulate or \
        commiserate on a number you haven't verified. Close by asking what they want to do with it: \
        extend it, adjust the target, mark it done, or let it go. Keep it short.
        """
    }

    /// Offer a look-back on a goal whose target date has passed. Once per goal, ever — the review is a
    /// moment, not a recurring reminder, and repeating it would turn a missed target into nagging.
    func runGoalReviewIfNeeded() async {
        guard proactiveLevel != .off, isConfigured, dataConsent, !sending else { return }
        guard let goal = ProactiveCoach.expiredGoalNeedingReview(CoachGoalStore.shared.goals) else {
            return
        }
        let stampKey = "coach.goalReviewed.\(goal.id.uuidString)"
        guard UserDefaults.standard.string(forKey: stampKey) == nil else { return }
        await runSeededTurnCancellable(
            instruction: Self.goalReviewInstruction(for: goal),
            prefix: "Your goal", stampKey: stampKey, origin: .nudge)
    }

    /// Fire a weekly review at most once every 7 logical days, only at the `normal` level and only when
    /// there's plan activity to review (#P10 13.2).
    func runWeeklyReviewIfNeeded() async {
        guard proactiveLevel == .normal, isConfigured, dataConsent, !sending else { return }
        let today = Repository.localDayKey(Date())
        if let last = UserDefaults.standard.string(forKey: Self.lastWeeklyReviewDayKey),
           let days = Self.dayKeyDistance(from: last, to: today), days < 7 { return }
        guard CoachPlanStore.shared.proposals.contains(where: { $0.status.isDecided }) else { return }
        await runSeededTurnCancellable(
            instruction: Self.weeklyReviewInstruction(toolsActive: toolCallingActive),
            prefix: "Weekly review", stampKey: Self.lastWeeklyReviewDayKey, origin: .weeklyReview)
    }

    /// Whole-day distance between two "yyyy-MM-dd" keys, or nil if either doesn't parse.
    static func dayKeyDistance(from: String, to: String) -> Int? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        guard let a = df.date(from: from), let b = df.date(from: to) else { return nil }
        return Calendar.current.dateComponents([.day], from: a, to: b).day
    }

    /// Cancellable runner for the proactive/weekly generated turns — mirrors `runCheckInCancellable` so
    /// the composer's Stop button cancels them too. Stamps its day key (via the generator) only on a
    /// non-empty success.
    private func runSeededTurnCancellable(instruction: String, prefix: String, stampKey: String,
                                          origin: ChatMessage.Origin) async {
        guard !sending else { return }
        let task = Task<Void, Never> { [weak self] in
            await self?.generateSeededTurn(instruction: instruction, prefix: prefix,
                                           stampKey: stampKey, origin: origin)
        }
        sendTask = task
        await task.value
        if sendTask == task { sendTask = nil }
    }

    /// Shared generation for an unprompted, seeded coach turn (proactive nudge / weekly review): the same
    /// history-carrying wire `generateCheckIn` builds, with the seed instruction as the trailing turn.
    /// Stamps `stampKey` with today's logical day only on a genuine, non-empty reply.
    private func generateSeededTurn(instruction: String, prefix: String, stampKey: String,
                                    origin: ChatMessage.Origin) async {
        guard isConfigured, dataConsent, !sending else { return }
        guard let key = resolvedKey else { return }
        clearError()
        sending = true
        defer { sending = false }

        await ensureOpenRouterCapabilities()

        let context = toolCallingActive ? toolModeContext : await buildFullContext()
        let relevant = CoachMemory.shared.relevantBlock(for: instruction, limit: 8)
        let preamble = [context, relevant]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let trailer = preamble.isEmpty ? instruction : preamble + "\n\n---\n\n" + instruction
        let history = Self.wirePairs(from: windowedMessages(), context: "")
        let wire = Self.appendTrailingUserTurn(history, content: trailer)
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: prefix + "\n\n" + clean,
                                            toolsUsed: reply.toolsUsed, origin: origin))
                UserDefaults.standard.set(Repository.logicalDayKey(Date()), forKey: stampKey)
            }
        } catch let e as AICoachError {
            setError(e)
        } catch {
            if !Self.isCancellation(error) {
                setError(error)
            }
        }
    }

    // MARK: - Card AI (#P11)

    /// Record that the coach was opened from a metric card, so the next Coach open gives a short read of
    /// it and offers its follow-up questions. Kept trivial (just state) so the button can fire it and
    /// immediately post the open notification; the generation happens on the Coach side.
    func openedFromCard(_ context: CoachCardContext) {
        pendingCardContext = context
    }

    /// System prompt for the cheap per-card read: the persona's voice, scoped to ONE metric and told to
    /// stay short, careful, and non-diagnostic — the "small AI on a card" role. Kept lean (no tool
    /// clauses) because it runs on the cheap card model with the figures handed to it, not tool calls.
    static func cardAnalysisSystem(persona: CoachPersona) -> String {
        persona.systemPreamble + "\n\n" + """
        You are giving a brief, careful read of ONE metric the user just opened. Two or three sentences: \
        what the value and its recent trend suggest, in plain language, and at most one gentle, optional \
        next step. Ground everything in the figures you are given — never invent data or numbers. This \
        is not a diagnosis and you are not a doctor. No bullet lists, no headings, no preamble.
        """
    }

    /// The user turn for a card read: the card's own title and factual summary, framed as a request.
    /// Pure/testable — the summary is what the card already computed.
    static func cardAnalysisUserTurn(for context: CoachCardContext) -> String {
        """
        I just opened my \(context.title) card. Here's what it shows:

        \(context.summary)

        Give me a short, careful read of this.
        """
    }

    /// Consume a pending card context: produce a short read of that one metric (11.4) on the cheap card
    /// model (11.5) and drop it into the chat as the opening coach message, then surface its follow-up
    /// questions (11.3). User-initiated (they tapped the card), so there is no daily lock — one read per
    /// tap — but it still respects connection + data-sharing consent like every other send.
    func runCardAnalysisIfNeeded() async {
        guard let context = pendingCardContext else { return }
        pendingCardContext = nil
        guard isConfigured, dataConsent, !sending else { return }
        clearError()
        sending = true
        defer { sending = false }

        let system = Self.cardAnalysisSystem(persona: persona)
        let user = Self.cardAnalysisUserTurn(for: context)
        guard let reply = await cheapComplete(system: system, user: user, role: .cardAnalysis) else {
            errorText = AICoachError.network("The card read didn't come through.").errorDescription
            return
        }
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        messages.append(ChatMessage(role: .assistant, text: context.title + "\n\n" + clean))
        cardSuggestions = context.suggestions
    }

    /// Pure: append a trailing user turn to already-wired history, keeping roles ALTERNATING. The
    /// Anthropic client maps wire pairs 1:1 with no coalescing, so two consecutive user turns would be a
    /// 400 — if the history already ends on a user turn (an errored send that left no reply), the new
    /// content folds into it rather than emitting a second user turn. Split out so it's unit-testable.
    nonisolated static func appendTrailingUserTurn(
        _ history: [(role: ChatMessage.Role, content: String)], content: String
    ) -> [(role: ChatMessage.Role, content: String)] {
        var wire = history
        if let last = wire.last, last.role == .user {
            wire[wire.count - 1] = (.user, last.content + "\n\n---\n\n" + content)
        } else {
            wire.append((.user, content))
        }
        return wire
    }

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    func buildFullContext() async -> String {
        var ctx = buildContext()
        ctx += "\n\n" + (await recentWorkoutsBlock())
        // Readiness (the SAME verdict Today's synthesis card shows) rides every full-context request —
        // not just the tool path — so a non-tool-calling provider (OpenAI/Gemini/Custom) can't drift from
        // what the user sees on Today either. Includes the health-signal safety note when relevant.
        ctx += "\n\n" + readinessBlock()
        // Charge confidence: whether today's number is a real, baseline-trusted score or still a
        // cold-start placeholder, so the coach never states progress/trends off a "calibrating" number.
        if let confidence = chargeConfidenceLine() { ctx += "\n\n" + confidence }
        // What's already proposed/agreed, so the coach doesn't talk over a plan the user is mid-way
        // through, plus how the last week actually went (skips carry their reason).
        if let plan = planContextBlock() { ctx += "\n\n" + plan }
        ctx += "\n\n" + (await planAdherenceBlock())
        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Gated here under `dataConsent` (the caller only reaches buildFullContext()
        // with consent on), so it rides the SAME consent + text-only channel as the HRV/RHR summary, a
        // derived number, never raw R-R egress. Omitted when there aren't enough clean beats yet.
        if let line = await stressIndexLine() { ctx += "\n\n" + line }
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { ctx += "\n\n" + block }
        }
        // Cross-conversation memory: a short digest of the user's recent past conversations, so the coach
        // has continuity across chats even on providers without tool-calling. Empty until chats are
        // summarised by the memory maintainer. Rides the same consent channel (buildFullContext only runs
        // with dataConsent on).
        let digest = recentSummariesDigest()
        if !digest.isEmpty { ctx += "\n\n" + digest }
        // The thread INDEX on top of the digest: a summary only exists once the memory maintainer has
        // run, so a thread from yesterday the user never left cleanly has none. Its title does exist —
        // and `CoachConversation.autoTitle` derives it from the user's FIRST question, so even on a
        // provider with no tool-calling this alone can answer "what did I ask you yesterday" in outline.
        let threads = recentThreadsIndex()
        if !threads.isEmpty { ctx += "\n\n" + threads }
        return ctx
    }

    // MARK: - Readiness / Charge drivers / clock

    /// The on-device Readiness verdict (`ReadinessEngine`) — the SAME algorithm Today's synthesis card
    /// reads, so the coach's push/maintain/rest call can never contradict what the user sees on Today.
    /// Includes ACWR (Gabbett) and Foster training monotony when there's enough strain history, plus a
    /// plain-English read of the contributing signals. When an active illness signal is present, appends
    /// a SAFETY note instructing the model not to suggest escalating training load — read fresh on every
    /// request rather than relying on the model to remember a static system-prompt rule.
    func readinessBlock() -> String {
        let readiness = ReadinessEngine.evaluate(days: repo.days, today: Repository.logicalDayKey(Date()))
        var lines = ["READINESS (\(readiness.level.rawValue)): \(readiness.headline)", readiness.summary]
        if let acwr = readiness.acwr {
            lines.append(String(format: "Acute:chronic workload ratio: %.2f", acwr))
        }
        if let monotony = readiness.monotony {
            lines.append(String(format: "Training monotony: %.2f", monotony))
        }
        if !readiness.signals.isEmpty {
            lines.append("Signals:")
            for s in readiness.signals { lines.append("  \(s.label): \(s.detail)") }
        }
        if let illness = illnessSignalProvider?(), illness.level != .quiet {
            lines.append("")
            lines.append("HEALTH SIGNAL: \(illness.copy)")
            lines.append("SAFETY: do not suggest increasing training load or intensity while this signal "
                         + "is present; favor rest, recovery, and seeing a professional if warranted.")
        }
        // Cycle phase, ONLY when the user opted in AND the engine actually detected one (never
        // `.learning`/`.unknown`) — the same gate + skin-temp/RHR/HRV z-scored inputs
        // `AppModel.computeCyclePhase()` uses for the Health hub's cards, so the two can't disagree.
        // Costs nothing for a user without cycle data: the UserDefaults check short-circuits first.
        if UserDefaults.standard.bool(forKey: AppModel.cycleAwarenessKey) {
            let (nights, baselineUsable) = Self.cyclePhaseNights(days: repo.days)
            let phase = CyclePhaseEngine.classify(nights, baselineUsable: baselineUsable)
            if phase.phase != .learning, phase.phase != .unknown {
                lines.append("")
                lines.append("Cycle phase (\(phase.confidence.rawValue) confidence): \(phase.note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Pure: builds `CyclePhaseEngine.Night` rows (+ whether the skin-temp baseline is usable) from
    /// daily history, exactly as `AppModel.computeCyclePhase()` does — nightly skin-temp deviation / RHR
    /// / HRV z-scored against their own folded baselines. Duplicated rather than shared (`AICoachEngine`
    /// has no `AppModel` reference) so `readinessBlock()`'s cycle-phase line can never disagree with the
    /// Health hub's skin-temp cards.
    static func cyclePhaseNights(days: [DailyMetric]) -> (nights: [CyclePhaseEngine.Night], baselineUsable: Bool) {
        guard let tempCfg = Baselines.metricCfg["skin_temp"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let hrvCfg = Baselines.metricCfg["hrv"] else { return ([], false) }
        let sorted = days.sorted { $0.day < $1.day }
        let skinState = Baselines.foldHistory(sorted.map { $0.skinTempDevC }, cfg: tempCfg)
        let rhrState = Baselines.foldHistory(sorted.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let hrvState = Baselines.foldHistory(sorted.map { $0.avgHrv }, cfg: hrvCfg)
        let nights: [CyclePhaseEngine.Night] = sorted.map { d in
            let tempZ = d.skinTempDevC.map {
                skinState.usable ? Baselines.deviation($0, state: skinState).z : $0 / 0.3
            }
            let rhrZ = rhrState.usable ? d.restingHr.map { Baselines.deviation(Double($0), state: rhrState).z } : nil
            let hrvZ = hrvState.usable ? d.avgHrv.map { Baselines.deviation($0, state: hrvState).z } : nil
            return CyclePhaseEngine.Night(day: d.day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ)
        }
        return (nights, skinState.usable)
    }

    /// The rest-quality term the Charge score was actually computed with: the Rest COMPOSITE ÷ 100,
    /// falling back to raw efficiency. Verbatim the derivation `IntelligenceEngine.recomputeRecovery` and
    /// `recomputeChargeDrivers` use, which is what wrote the stored number — so the coach's breakdown and
    /// the Today sheet's cannot describe different terms.
    ///
    /// This term used to be passed as `nil` here, on the documented assumption that it needed the app's
    /// merged/carried sleep-performance resolution and was therefore out of reach without an `AppModel`.
    /// It isn't: `Rest.composite(daily:)` is pure and row-local. Passing nil silently DROPPED the rest
    /// row from the coach's breakdown, so the coach explained a Charge the Today screen explained
    /// differently — the one thing the "never contradict Today" rule exists to prevent.
    static func restQualityTerm(_ daily: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
    }

    /// The row the breakdown describes, mirroring `TodayView.chargeBreakdownRow`: today's own row once
    /// it's scored, otherwise the most recent row that HAS a Charge score. Without the carry, the coach
    /// would answer "not enough data yet" on a rollover morning while the Today ring still displays the
    /// carried night's number — a second way for the two to disagree.
    static func chargeBreakdownRow(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        let today = days.last { $0.day == todayKey }
        if let today, today.recovery != nil { return today }
        return days.last { $0.recovery != nil } ?? today ?? days.last
    }

    /// The ordered "why is my Charge what it is" breakdown (`ChargeDrivers`), computed from the SAME
    /// per-term inputs `RecoveryScorer.recovery` uses, so the coach explains the REAL contributing terms
    /// instead of inventing a plausible-sounding story. A term whose input is missing produces no row,
    /// never a fabricated one. The rest-quality (sleep performance) term IS threaded through now, via
    /// `restQualityTerm` — see there for why the earlier "out of scope" note was wrong and what it cost.
    func chargeDriversBlock() -> String {
        let days = repo.days
        let todayKey = Repository.logicalDayKey(Date())
        guard let today = Self.chargeBreakdownRow(days: days, todayKey: todayKey),
              let hrv = today.avgHrv, let rhr = today.restingHr else {
            return "Not enough data yet to break down today's Charge."
        }
        let hrvBase = Baselines.foldHistory(days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        guard hrvBase.usable else { return "Still calibrating the HRV baseline — no Charge breakdown yet." }
        let rhrBase = Baselines.foldHistory(days.map { $0.restingHr.map(Double.init) },
                                            cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(days.map(\.respRateBpm), cfg: Baselines.respCfg)
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: today.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: Self.restQualityTerm(today), skinTempDev: today.skinTempDevC)
        guard !drivers.isEmpty else { return "No Charge breakdown available yet." }
        var lines = ["WHY TODAY'S CHARGE IS WHAT IT IS (signed points, biggest mover first):"]
        for d in drivers {
            let sign = d.deltaPoints >= 0 ? "+" : ""
            let vsBaseline = d.baselineText.isEmpty ? "" : " vs \(d.baselineText)"
            lines.append("  \(d.label): \(sign)\(d.deltaPoints) pts — \(d.valueText)\(vsBaseline) — \(d.verdict)")
        }
        return lines.joined(separator: "\n")
    }

    /// Today's Charge confidence tier (`ScoreConfidence.charge`), computed identically to the Today
    /// screen — against the SAME folded HRV baseline — so the coach can tell a real 62 from a cold-start
    /// placeholder instead of treating every number as equally trustworthy. nil when there's no row to
    /// judge. Effort/Rest confidence need additional store reads (HR sample density, sleep-session
    /// matching) not cheaply available from `repo.days` alone; a later pass can add them.
    ///
    /// Internal (not private): `CoachTools.runCoachTool` appends this to the `get_biometric_summary` and
    /// `get_charge_drivers` tool OUTPUTS on the tool path, where `buildFullContext()` never runs — the
    /// line has to travel with the number it qualifies rather than live in a context block the tool path
    /// never sees.
    func chargeConfidenceLine() -> String? {
        let days = repo.days
        let todayKey = Repository.logicalDayKey(Date())
        guard let today = days.last(where: { $0.day == todayKey }) ?? days.last else { return nil }
        let hrvBase = Baselines.foldHistory(days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        let confidence = ScoreConfidence.charge(recovery: today.recovery, hrvBaseline: hrvBase)
        var line = "Charge confidence today: \(confidence.rawValue)"
        if confidence == .calibrating {
            line += " (not a real score yet — the HRV baseline is still building; do not state progress, "
                  + "trends or comparisons off this number)"
        }
        return line
    }

    /// One block per active goal (#R-multi-goal), plus any goal closed within the last 14 days (long
    /// enough for the coach to acknowledge a fresh "achieved"/"set aside", short enough that a year of
    /// closed goals doesn't accumulate as context noise — `CoachGoal` has no dedicated `closedAt` field,
    /// so the closing history event's own date stands in for it). When more than one goal is active, an
    /// explicit instruction tells the model to weigh across all of them rather than address just one.
    private func goalsBlock(profile: ProfileStore) -> String? {
        let store = CoachGoalStore.shared
        let recencyCutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        let recentlyClosed = store.goals.filter { g in
            (g.status == .achieved || g.status == .abandoned)
                && (g.history.last?.date ?? .distantPast) >= recencyCutoff
        }
        let blocks = (store.activeGoals + recentlyClosed).compactMap { goalBlock(for: $0, profile: profile) }
        guard !blocks.isEmpty else { return nil }

        var result = blocks.joined(separator: "\n\n")
        if store.activeGoals.count > 1 {
            result += "\n\nThe user has \(store.activeGoals.count) active goals above — weigh and "
                    + "prioritise across ALL of them in your recommendations (e.g. don't suggest a hard "
                    + "run day that conflicts with a strength day both goals need); do not address only "
                    + "one and ignore the rest."
        }
        return result
    }

    /// One goal, with the arithmetic done: how long is left, how much change remains, roughly where in
    /// the runway we are, and — crucially — the deterministic safety verdict on the rate it demands, so
    /// the model narrates a judgement made in code rather than forming its own.
    ///
    /// `motivation` is included ONLY when the user explicitly opted in (`shareMotivation`). It is the
    /// most personal line in the app and it stays on the device by default.
    private func goalBlock(for goal: CoachGoal, profile: ProfileStore) -> String? {
        let title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // A CLOSED goal still matters for one conversation beat: the coach should congratulate (or
        // respect the decision to stop) instead of coaching towards a goal that no longer exists.
        switch goal.status {
        case .achieved:
            return "Goal: \"\(title)\" — ACHIEVED (the user marked it done). Congratulate them when it "
                 + "fits naturally, and ask what's next before proposing any new target yourself."
        case .abandoned:
            return "The user's previous goal \"\(title)\" was set aside by them. Do not nag about it or "
                 + "treat it as a failure; whether and when to set a new goal is their call."
        case .paused, .archived:
            return nil
        case .active:
            break
        }

        var parts = ["Goal: \(title)"]
        if goal.kind.isQuantified, let target = goal.target {
            var quantified = String(format: "target %g %@", target, goal.kind.unit)
            if let baseline = goal.baseline {
                quantified += String(format: " (from %g %@)", baseline, goal.kind.unit)
            }
            parts.append(quantified)
        }
        if let weeks = goal.weeksRemaining() {
            if weeks < 0 {
                parts.append("target date has PASSED")
            } else {
                parts.append(String(format: "%.0f weeks remaining", weeks.rounded()))
            }
        }
        if let phase = goal.phase() { parts.append("phase: \(phase)") }
        var lines = [parts.joined(separator: " — ")]

        // The rate verdict, decided in code before the model ever sees it.
        let gate = GoalSafetyGate.assess(goal: goal, bodyWeightKg: profile.weightKg)
        if let warning = gate.warning {
            lines.append("GOAL PACE (\(gate.verdict.rawValue)): \(warning)")
        }
        if let ack = goal.acknowledgedRisk {
            let when = ack.date.formatted(date: .abbreviated, time: .omitted)
            lines.append("The user acknowledged this pace on \(when): \"\(ack.reason)\". Respect that "
                         + "decision — coach them through it rather than relitigating it, and keep "
                         + "flagging recovery signals honestly.")
        }
        if goal.kind == .weight {
            lines.append("NOTE: NOOP holds no nutrition data. Plan TRAINING around this goal and say "
                         + "plainly that diet is outside what you can see.")
        }
        // The structured WHY (motivation tags): coarse categories the user picked, so the coach can
        // frame advice around what they're actually after (8.4). Not the intimate free-text — that's the
        // opt-in below.
        if !goal.motivationTags.isEmpty {
            let tags = goal.motivationTags.map(\.label).joined(separator: ", ")
            lines.append("What they're after: \(tags). Frame progress and suggestions around these.")
        }
        if goal.shareMotivation {
            let motivation = goal.motivation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !motivation.isEmpty { lines.append("Why it matters to them: \(motivation)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Journey (read-only accessors for the Journey page)

    /// The current on-device Readiness verdict, straight from the engine — for surfaces (like the
    /// Journey page) that want to render it with their own styling rather than consume the text block
    /// built for the model. Calls the SAME `ReadinessEngine.evaluate` the coach's context and Today's
    /// synthesis card use, so this can never disagree with either.
    func currentReadiness() -> ReadinessEngine.Readiness {
        ReadinessEngine.evaluate(days: repo.days, today: Repository.logicalDayKey(Date()))
    }

    /// The most recent Apple-Health-logged body weight (kg), or nil if none has ever synced. Kept
    /// separate from `ProfileStore.weightKg`, which is a manually-set profile default, not a
    /// measurement — callers should label which one they're showing rather than conflate them.
    func latestLoggedWeightKg() async -> Double? {
        let rows = await repo.series(key: "weight", source: "apple-health", days: 365)
        return rows.sorted(by: { $0.day < $1.day }).last?.value
    }

    /// Mean Charge over a trailing window, counting ONLY days whose score the app itself trusts
    /// (skipping `.calibrating` rows) — so a recovery-trend read is never built from placeholder
    /// numbers. `endingDaysAgo` lets the caller ask for the window before this one (e.g. "last week"
    /// vs "the week before"), for a simple week-over-week comparison. nil when nothing usable falls
    /// inside the window.
    func meanTrustedCharge(lastDays days: Int, endingDaysAgo offset: Int = 0) -> Double? {
        let sorted = repo.days.sorted { $0.day < $1.day }
        guard !sorted.isEmpty else { return nil }
        let endIndex = sorted.count - offset
        guard endIndex > 0 else { return nil }
        let window = sorted[max(0, endIndex - days)..<endIndex]
        guard !window.isEmpty else { return nil }
        let hrvBase = Baselines.foldHistory(sorted.map(\.avgHrv), cfg: Baselines.hrvCfg)
        let trusted = window.compactMap { row -> Double? in
            guard let r = row.recovery,
                  ScoreConfidence.charge(recovery: r, hrvBaseline: hrvBase) != .calibrating else { return nil }
            return r
        }
        guard !trusted.isEmpty else { return nil }
        return trusted.reduce(0, +) / Double(trusted.count)
    }

    // MARK: - Plan: inputs, adherence, context

    /// Assemble everything `PlanConsequence` needs from the repository, in one pass. Sports come from
    /// the user's OWN workout history (not a fixed vocabulary), which is what lets the cost figures be
    /// about them rather than about runners in general.
    func planInputs() async -> PlanConsequence.Inputs {
        let days = repo.days   // oldest → newest
        var inputs = PlanConsequence.Inputs()
        inputs.recoveryByDay = Dictionary(days.compactMap { d in d.recovery.map { (d.day, $0) } },
                                          uniquingKeysWith: { _, last in last })
        inputs.recentCharge = days.compactMap { $0.recovery }
        inputs.recentEffort = days.compactMap { $0.strain }

        let sleeps = days.suffix(RecoveryForecaster.baselineWindow).compactMap { $0.totalSleepMin }
        if !sleeps.isEmpty {
            inputs.typicalSleepHours = (sleeps.reduce(0, +) / Double(sleeps.count)) / 60
            inputs.sleepNights = sleeps.count
        }

        // Tag each day with the sports done on it, from the workout rows themselves.
        let rows = await repo.workoutRows(days: 365)
        var bySport: [String: Set<String>] = [:]
        for w in rows {
            bySport[w.sport, default: []].insert(dateString(w.startTs))
        }
        inputs.activityDaysBySport = bySport
        return inputs
    }

    /// What the user committed to versus what actually happened.
    ///
    /// GATED ON CONFIDENCE: a day whose Charge is still `.calibrating` is a placeholder, not a
    /// measurement, so it gets no adherence verdict. Grading someone against numbers the app itself
    /// doesn't trust is exactly the kind of confident nonsense this whole phase exists to prevent.
    /// Skips are reported WITH their reason — "didn't train" without "because my knee hurt" is a
    /// scoreboard, not coaching.
    func planAdherenceBlock(days: Int = 7) async -> String {
        let store = CoachPlanStore.shared
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -max(1, days), to: Date()) ?? Date()
        let fromKey = Repository.localDayKey(from)
        let relevant = store.proposals
            .filter { $0.day >= fromKey && $0.status.isDecided }
            .sorted { $0.day > $1.day }
        guard !relevant.isEmpty else {
            return "PLAN: nothing has been proposed or agreed in the last \(days) days."
        }

        let hrvBase = Baselines.foldHistory(repo.days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })

        var lines = ["PLAN vs WHAT HAPPENED (last \(days) days):"]
        for p in relevant.prefix(14) {
            var line = "  \(p.day): \(p.summary()) — \(p.status.rawValue)"
            if let reason = p.skipReason { line += " (\(reason.label))" }
            // Only quote the day's real Effort when the app actually trusts that day's numbers.
            if let row = byDay[p.day] {
                let confidence = ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase)
                if confidence == .calibrating {
                    line += " — that day's data is still calibrating, so don't read progress into it"
                } else if let effort = row.strain {
                    line += String(format: " — actual effort %.1f", effort)
                }
            }
            lines.append(line)
        }

        // The filter-bubble floor. Without this, a run of "not today"s quietly trains the coach into
        // never asking for anything again, which feels supportive and is actually abandonment.
        if store.declineStreak >= CoachPlanStore.declineStreakFloor {
            lines.append("NOTE: the user has declined \(store.declineStreak) suggestions in a row. Don't "
                         + "just keep making them easier — ask what's actually getting in the way "
                         + "(time, motivation, the sessions themselves), and keep offering real work "
                         + "once you know.")
        }
        if let caution = store.recentCautionSkip() {
            lines.append("CAUTION: a recent session was skipped due to \(caution.skipReason?.label ?? "pain/illness"). "
                         + "Do not propose an escalation; check in on it first.")
        }
        return lines.joined(separator: "\n")
    }

    /// Pending proposals + upcoming commitments, so the coach knows what's already on the table instead
    /// of proposing over the top of it. `store` is injectable so the block can be exercised without the
    /// singleton; production always passes the default.
    func planContextBlock(store: CoachPlanStore = .shared) -> String? {
        let today = Repository.localDayKey(Date())
        var lines: [String] = []
        let pending = store.pending.filter { $0.day >= today }
        if !pending.isEmpty {
            lines.append("AWAITING THE USER'S DECISION (you proposed these; they haven't answered):")
            for p in pending.prefix(5) { lines.append("  \(p.day): \(p.summary())") }
        }
        let committed = store.commitments(fromDay: today)
        if !committed.isEmpty {
            lines.append("THE USER HAS COMMITTED TO (do NOT propose any of these again — comment on them, "
                         + "adjust them if asked, but they're already on the table):")
            for p in committed.prefix(7) {
                var line = "  \(p.day): \(p.summary())"
                // Mark the ORIGIN so the coach doesn't re-pitch the user's OWN routine as its idea (#P7 9.8).
                switch p.source {
                case .userCreated: line += " — the user's own session"
                case .userSwapped: line += p.swappedFrom.map { " (swapped from \($0))" } ?? ""
                case .coachProposed: line += p.swappedFrom.map { " (swapped from \($0))" } ?? ""
                }
                if let from = p.rescheduledFrom { line += " (moved from \(from))" }
                lines.append(line)
            }
        }
        if let pattern = Self.skipPatternLine(store.proposals) { lines.append(pattern) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A factual line about WHY sessions have recently been skipped, when one reason clearly dominates.
    ///
    /// `pain` and `ill` already reached the coach through the CAUTION line in `planAdherenceBlock`,
    /// because those carry a safety implication. The everyday reasons — no time, too tired, not feeling
    /// it — were recorded by the UI and then read by nobody, so the coach kept proposing into the same
    /// wall. This is deliberately a STATEMENT OF FACT, not an instruction: the model is told what
    /// happened, and decides what to do about it. Nothing here hides a sport or shrinks a plan on its
    /// own — `declineStreakFloor` remains the guard against a filter bubble.
    static func skipPatternLine(_ proposals: [PlanProposal], minimum: Int = 3) -> String? {
        let skipped = proposals.filter { $0.status == .skipped }
        var counts: [PlanProposal.SkipReason: Int] = [:]
        for p in skipped {
            // Excludes pain/ill on purpose: those are a safety signal, already surfaced with the weight
            // they deserve. Folding them in here would restate a health concern as a scheduling habit.
            guard let reason = p.skipReason, !reason.triggersCaution else { continue }
            counts[reason, default: 0] += 1
        }
        guard let (reason, count) = counts.max(by: { $0.value < $1.value }), count >= minimum else {
            return nil
        }
        return "PATTERN: the user's last \(count) skipped sessions were \"\(reason.label)\". State this "
            + "plainly if you propose something similar, and ask what would actually fit — do not "
            + "quietly stop suggesting that kind of session."
    }

    // MARK: - Plan tools

    /// `propose_plan`: record a SUGGESTION. Note what this deliberately cannot do — it cannot accept,
    /// schedule, or activate anything. The proposal sits in `.proposed` until the user taps yes, and the
    /// returned string tells the model to say exactly that rather than describing it as settled.
    func proposePlanTool(day: String?, sport: String, intent: String,
                         targetEffort: Double?, rationale: String, time: String?) -> String {
        let trimmedSport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSport.isEmpty else { return "Nothing proposed: name the activity." }
        guard let parsedIntent = PlanProposal.Intent(rawValue: intent.lowercased()) else {
            return "Nothing proposed: intent must be one of rest, easy, moderate, hard, mobility."
        }
        let requestedDay = (day ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dayKey = requestedDay.isEmpty ? Repository.localDayKey(Date()) : requestedDay

        // "HH:mm" on the proposal's own day — a time without its day would silently land on today.
        var when: Date?
        if let time, !time.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            df.timeZone = .current
            when = df.date(from: "\(dayKey) \(time)")
        }

        let proposal = PlanProposal(day: dayKey, time: when, sport: trimmedSport,
                                    intent: parsedIntent,
                                    targetEffort: targetEffort.map { max(0, min($0, 100)) },
                                    rationale: rationale)
        guard CoachPlanStore.shared.propose(proposal) else {
            // The user already has this exact session committed for that day (their own routine, or a
            // proposal they accepted) — the store refused the duplicate (#P7 9.8/10.5). Tell the model so
            // it acknowledges what's already there instead of re-pitching it.
            return "Not proposed: the user already has \(trimmedSport) committed for \(dayKey). "
                + "Acknowledge their existing plan rather than suggesting it again as if it were new."
        }
        return "Proposed (NOT scheduled): \(proposal.summary()) on \(dayKey). It's waiting for the user "
            + "to accept, change or decline it in the app — tell them it's there for their yes, and "
            + "don't refer to it as booked."
    }

    /// `get_session_outlook`: what a session costs THIS user, and what swapping would change.
    func sessionOutlookTool(sport: String, swapFrom: String?,
                            plannedEffort: Double?, plannedSleepHours: Double?) async -> String {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Name the activity to size up." }
        let inputs = await planInputs()
        if let from = swapFrom?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty {
            return PlanConsequence.compare(from: from, fromEffort: plannedEffort,
                                           to: trimmed, toEffort: plannedEffort,
                                           plannedSleepHours: plannedSleepHours,
                                           inputs: inputs).sentence()
        }
        return PlanConsequence.outlook(sport: trimmed, plannedEffort: plannedEffort,
                                       plannedSleepHours: plannedSleepHours,
                                       inputs: inputs).sentence()
    }

    /// `simulate_day`: the what-if. Returns an honest "not enough history" rather than a made-up number.
    func simulateDayTool(effort: Double?, sleepHours: Double?) async -> String {
        guard let sleepHours else { return "Tell me how many hours you plan to sleep and I'll project it." }
        let inputs = await planInputs()
        return PlanConsequence.simulate(todayEffort: effort.map { max(0, min($0, 100)) },
                                        plannedSleepHours: max(0, sleepHours),
                                        inputs: inputs)
            ?? "There isn't enough recent Charge history to project tomorrow honestly yet."
    }

    /// VO₂max estimate from the same inputs the Fitness Age screen and `IntelligenceEngine.fitnessAgeRows`
    /// use (median resting HR + strain-derived PA index over the last 7 days); nil without a waist
    /// measurement, exactly as `FitnessAgeEngine` specifies. Shared by `goalEvidence()` (goal feasibility)
    /// and `buildContext()` (chat), so the two can never disagree.
    private func estimatedVO2max(days: [DailyMetric], profile: ProfileStore) -> Double? {
        let gate7 = Array(days.suffix(7))
        let rhrs = gate7.compactMap { $0.restingHr }.map(Double.init)
        guard !rhrs.isEmpty, profile.age > 0, profile.waistCm > 0 else { return nil }
        let strains = gate7.compactMap { $0.strain }.filter { $0 >= 30 }
        let meanStrain = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        let sorted = rhrs.sorted()
        let medianRHR = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return FitnessAgeEngine.compute(
            age: Double(profile.age), sex: profile.sex, restingHR: medianRHR,
            paIndex: FitnessAgeEngine.physicalActivityIndexFromStrain(
                activeDaysPerWeek: strains.count, meanActiveStrain: meanStrain),
            waistCm: profile.waistCm)?.vo2max
    }

    /// Gather what the app can actually measure about the user's starting point, for the feasibility
    /// check. Every field degrades to nil rather than guessing. VO₂max mirrors
    /// `IntelligenceEngine.fitnessAgeRows`'s assembly (median resting HR + strain-derived PA index over
    /// the recent gate window) and is nil without a waist measurement, exactly as `FitnessAgeEngine`
    /// specifies — it is reported as context, never used to predict.
    func goalEvidence() async -> GoalFeasibility.Evidence {
        let days = repo.days
        let profile = ProfileStore()
        var evidence = GoalFeasibility.Evidence()

        // VO₂max (context only): the same inputs the Fitness Age screen uses.
        evidence.vo2max = estimatedVO2max(days: days, profile: profile)

        // Running base + weekly session count, from the last 30 days of workouts.
        let rows = await repo.workoutRows(days: 30)
        let runDistances = rows
            .filter { $0.sport.lowercased().contains("run") }
            .compactMap { $0.distanceM }
            .map { $0 / 1000 }
        if let longest = runDistances.max(), longest > 0 { evidence.longestRecentRunKm = longest }
        if !rows.isEmpty { evidence.sessionsPerWeek = Double(rows.count) / (30.0 / 7.0) }

        // Recent mean sleep.
        let sleeps = days.suffix(14).compactMap { $0.totalSleepMin }
        if !sleeps.isEmpty {
            evidence.meanSleepHours = (sleeps.reduce(0, +) / Double(sleeps.count)) / 60
        }
        return evidence
    }

    /// Today's date, weekday and rough time of day, so the coach is never guessing what "today" means —
    /// the historical gap that let it not know a workout was 5 days ago or that it's a rest day of the week.
    ///
    /// Internal rather than private because `toolModeContext` (`CoachTools.swift`) needs it too: the tool
    /// path used to carry NO clock at all, so a relative question ("what did I ask you yesterday?") had
    /// nothing to resolve "yesterday" against. Deliberately NOT in the system prompt — that block carries
    /// Anthropic's `cache_control` breakpoint, and a time-of-day string that changes every request would
    /// invalidate the prefix cache on every single turn.
    func clockLine() -> String {
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "EEEE, yyyy-MM-dd"
        let hour = Calendar.current.component(.hour, from: now)
        let partOfDay: String
        switch hour {
        case 0..<5: partOfDay = "late night"
        case 5..<12: partOfDay = "morning"
        case 12..<17: partOfDay = "afternoon"
        case 17..<21: partOfDay = "evening"
        default: partOfDay = "night"
        }
        return "Right now: \(df.string(from: now)), \(partOfDay)."
    }

    /// Whole days between `ts` (unix seconds) and now, using calendar day boundaries (not a raw 24h
    /// division), so "yesterday evening" reads as 1 day ago rather than 0.
    private func daysAgo(_ ts: Int) -> Int {
        Self.daysAgo(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// The same calendar-day arithmetic for a `Date`. Static and pure so the recall tests can pin the
    /// "yesterday means 1, not 24 hours" behaviour without an engine. `now` is injectable for the same
    /// reason — a test that builds "yesterday" relative to a fixed clock can't flake at midnight.
    static func daysAgo(_ date: Date, now: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: date),
                                  to: cal.startOfDay(for: now)).day ?? 0
    }

    // MARK: - Cross-conversation recall

    /// A one-line-per-chat digest of the user's most recent summarised conversations (excluding the
    /// active one), for continuity across chats. Empty when nothing is summarised yet.
    func recentSummariesDigest(limit: Int = 5) -> String {
        let recent = conversations
            .filter { $0.id != activeConversationID && !($0.summary ?? "").isEmpty }
            .prefix(limit)
        guard !recent.isEmpty else { return "" }
        var lines = ["SUMMARIES OF THE USER'S RECENT PAST CONVERSATIONS (for continuity):"]
        for c in recent {
            let date = c.updatedAt.formatted(date: .abbreviated, time: .omitted)
            lines.append("• [\(date)] \(c.summary ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    /// A cheap index of the user's recent threads: title + date only, no summaries, no message bodies.
    /// Rides the tool-path context so the model KNOWS past conversations exist and can decide to search
    /// them. `recentSummariesDigest()` can't do this job alone — it needs a `summary`, which the memory
    /// maintainer only writes when the user leaves a chat with enough new turns, so a thread from
    /// yesterday that was never summarised is invisible to it. A title exists from the first user turn.
    func recentThreadsIndex(limit: Int = 5) -> String {
        Self.threadsIndex(conversations, activeID: activeConversationID, limit: limit)
    }

    /// Static and pure so it's unit-testable without an engine — `conversations` is `private(set)`, so a
    /// test can't seed the instance. Same reason `now` is injectable.
    static func threadsIndex(_ conversations: [CoachConversation],
                             activeID: UUID?,
                             limit: Int = 5,
                             now: Date = Date()) -> String {
        let recent = conversations
            .filter { $0.id != activeID && !$0.messages.isEmpty }
            .prefix(limit)
        guard !recent.isEmpty else { return "" }
        var lines = ["THE USER'S RECENT THREADS WITH YOU (titles only — use search_past_conversations "
                     + "to read one):"]
        for c in recent {
            lines.append("• \(relativeStamp(c.updatedAt, now: now)) — "
                         + (c.title.isEmpty ? "Untitled" : c.title))
        }
        return lines.joined(separator: "\n")
    }

    /// Recall over the user's PAST conversations, on two INDEPENDENT axes:
    ///   • **keyword** — token overlap against `query` (the original behaviour), and/or
    ///   • **time** — `onDaysAgo` (one calendar day: 0 = today, 1 = yesterday) or `sinceDays` (a window).
    ///
    /// Either axis works alone, and that's the whole point of the time one: "what did I ask you
    /// yesterday?" carries no content keywords, so a keyword-only search scored every thread at zero and
    /// the coach answered "I don't have that". Requiring `query` made a purely temporal question
    /// structurally unanswerable.
    ///
    /// The snippet returns the user's OWN turns, not the coach's. The previous version emitted the
    /// summary or the LAST message — usually the coach's own reply — which cannot answer "what did *I*
    /// ask". Deterministic and on-device; no embeddings, no extra API call.
    func searchPastConversations(query: String = "",
                                 sinceDays: Int? = nil,
                                 onDaysAgo: Int? = nil,
                                 limit: Int = 3) -> String {
        Self.recallText(conversations, activeID: activeConversationID, query: query,
                        sinceDays: sinceDays, onDaysAgo: onDaysAgo, limit: limit)
    }

    /// The recall itself, static and pure — `conversations` is `private(set)`, so the tests drive this
    /// entry point with a seeded list and a fixed `now` instead of an engine.
    static func recallText(_ conversations: [CoachConversation],
                           activeID: UUID?,
                           query: String = "",
                           sinceDays: Int? = nil,
                           onDaysAgo: Int? = nil,
                           limit: Int = 3,
                           now: Date = Date()) -> String {
        let qTokens = CoachMemory.tokens(query)
        let hasTimeFilter = sinceDays != nil || onDaysAgo != nil
        let candidates = conversations.filter { $0.id != activeID }

        // Match on MESSAGE dates, not the conversation's `updatedAt`: a thread the user reopened today
        // would otherwise hide everything they actually asked in it yesterday.
        func messagesInWindow(_ convo: CoachConversation) -> [ChatMessage] {
            guard hasTimeFilter else { return convo.messages }
            return convo.messages.filter { msg in
                let age = daysAgo(msg.date, now: now)
                if let exact = onDaysAgo { return age == exact }
                if let since = sinceDays { return age <= since && age >= 0 }
                return true
            }
        }

        var hits: [(convo: CoachConversation, window: [ChatMessage], score: Int)] = []
        for convo in candidates {
            let window = messagesInWindow(convo)
            if hasTimeFilter && window.isEmpty { continue }
            let hay = ([convo.title, convo.summary ?? ""] + window.map(\.text)).joined(separator: " ")
            let score = qTokens.isEmpty ? 0 : CoachMemory.tokens(hay).intersection(qTokens).count
            // A keyword-only search still requires a hit. With a time filter the window IS the match, so
            // a zero score just means "no keywords given" or "keywords didn't help rank" — keep it.
            if !hasTimeFilter && score == 0 { continue }
            hits.append((convo, window, score))
        }

        guard !hits.isEmpty else {
            return noRecallMatch(query: query, sinceDays: sinceDays, onDaysAgo: onDaysAgo)
        }

        // With keywords, rank by overlap; without, the newest thread is the most relevant one.
        if qTokens.isEmpty {
            hits.sort { $0.convo.updatedAt > $1.convo.updatedAt }
        } else {
            hits.sort { $0.score > $1.score }
        }

        var lines = ["Relevant past conversations:"]
        for hit in hits.prefix(limit) {
            let title = hit.convo.title.isEmpty ? "Untitled" : hit.convo.title
            lines.append("• [\(title), \(relativeStamp(hit.convo.updatedAt, now: now))]")
            let asked = hit.window.filter { $0.role == .user && !$0.text.isEmpty }
            for msg in asked.prefix(recallUserTurnsPerThread) {
                lines.append("    the user asked: \"\(trimmed(msg.text, to: 160))\"")
            }
            if asked.isEmpty {
                // An auto-only thread (a brief or nudge the user never replied to) — say so rather than
                // silently returning a bare title.
                lines.append("    (no questions from the user in this thread — coach-initiated)")
            }
            if let summary = hit.convo.summary, !summary.isEmpty {
                lines.append("    summary: \(trimmed(summary, to: 240))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// How many of the user's own turns to quote per matched thread. Enough to answer "what did I ask
    /// you yesterday" for a normal chat, small enough that three threads can't blow up the tool result.
    private static let recallUserTurnsPerThread = 3

    /// The "nothing found" text, phrased against whichever axis the caller actually used — so the model
    /// can tell "you have no chats from yesterday" apart from "your keywords didn't match".
    private static func noRecallMatch(query: String, sinceDays: Int?, onDaysAgo: Int?) -> String {
        if let exact = onDaysAgo {
            let when = exact == 0 ? "today" : (exact == 1 ? "yesterday" : "\(exact) days ago")
            return "No conversations from \(when)."
        }
        if let since = sinceDays { return "No conversations in the last \(since) days." }
        if query.isEmpty { return "No past conversations stored yet." }
        return "No past conversations match \"\(query)\"."
    }

    /// A date the model can reason about: "yesterday (Mon 20 Jul, 18:42)" rather than a bare date. Recent
    /// threads carry the time too, because "what did I ask this morning" needs it.
    private static func relativeStamp(_ date: Date, now: Date = Date()) -> String {
        let age = daysAgo(date, now: now)
        let withTime = date.formatted(date: .abbreviated, time: .shortened)
        switch age {
        case 0: return "today (\(withTime))"
        case 1: return "yesterday (\(withTime))"
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private static func trimmed(_ text: String, to limit: Int) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }

    // MARK: - Model roles

    /// The model id to use for a given ROLE (`CoachModelRole`), resolved in priority order:
    ///   1. the user's explicit per-role override, if any (`.chat` → `model`; others → their setting);
    ///   2. the provider's built-in default for that role (strong for chat, cheap for the rest);
    ///   3. the resolved CHAT model, so a role is never left pointing at an empty string.
    /// Single resolution point so every caller (chat send, summary upkeep, card analysis) agrees, and so
    /// the fallback chain can't drift between them.
    func model(for role: CoachModelRole) -> String {
        func firstNonEmpty(_ values: String...) -> String {
            values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        }
        switch role {
        case .chat:
            return firstNonEmpty(model, provider.defaultModel)
        case .summary:
            return firstNonEmpty(memoryModel, provider.cheapModel, model, provider.defaultModel)
        case .cardAnalysis:
            return firstNonEmpty(cardModel, provider.cheapModel, model, provider.defaultModel)
        case .deepAnalysis:
            // Falls back to the chat model so a caller can never end up with an empty id, but callers
            // are expected to check `hasDeepAnalysisModel` first — a "deep" run on the ordinary model
            // is just the same answer at twice the cost.
            return firstNonEmpty(deepModel, model, provider.defaultModel)
        }
    }

    // MARK: - Memory maintenance support (cheap-model one-off calls)

    /// The outcome of a connection test, as something the UI can render without re-deriving anything.
    enum ConnectionTestResult: Equatable {
        case untested
        case testing
        case ok(model: String)
        case failed(String)
    }

    @Published private(set) var connectionTest: ConnectionTestResult = .untested

    /// Send the smallest possible real request and report what came back.
    ///
    /// Until now a wrong key, a typo'd Custom URL or a model id the provider doesn't serve was only
    /// discovered by asking the coach a real question and getting an error instead of an answer — after
    /// the user had already left settings and composed something. This answers "did that work?" at the
    /// moment the key is pasted, which is when the user still has the context to fix it.
    ///
    /// Deliberately goes through the ORDINARY send path (`provider.client.send`) rather than pinging
    /// `/models`: fetching a model list can succeed with a key that the chat endpoint then rejects, and
    /// it says nothing about whether the SELECTED model is actually servable to this account.
    func testConnection() async {
        // `resolvedKey` already yields "" for Custom (a local server usually needs none), so nil here
        // genuinely means "no key for a provider that requires one".
        guard let key = resolvedKey else {
            connectionTest = .failed(AICoachError.noKey.errorDescription ?? "")
            return
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            connectionTest = .failed(AICoachError.noModel.errorDescription ?? "")
            return
        }

        connectionTest = .testing
        do {
            _ = try await provider.client.send(
                key: key,
                model: model,
                systemPrompt: "Reply with the single word: ok",
                messages: [(role: .user, content: "ok")],
                session: session
            )
            connectionTest = .ok(model: model)
        } catch {
            // Same classification the chat uses, so "you're offline" reads identically in both places
            // rather than being a second, subtly different vocabulary for the same failures.
            let coachError = (error as? AICoachError) ?? coachTransportError(error)
            connectionTest = .failed(coachError.errorDescription ?? "")
        }
    }

    /// Drop a stale verdict — on provider/key/model change, the previous result no longer describes
    /// what would happen now, and a lingering green tick is worse than none.
    func resetConnectionTest() { connectionTest = .untested }

    /// A one-off completion via the CHEAP model for a background role (summary upkeep or a card analysis).
    /// Internal so `MemoryMaintainer` (and the card-AI feature) can drive short calls without touching the
    /// private key. Returns nil on ANY failure — this work is best-effort and never surfaces an error.
    func cheapComplete(system: String, user: String, role: CoachModelRole = .summary) async -> String? {
        guard let key = resolvedKey else { return nil }
        do {
            return try await provider.client.send(
                key: key, model: model(for: role), systemPrompt: system,
                messages: [(role: .user, content: user)], session: session
            )
        } catch { return nil }
    }

    /// Write a generated summary back onto a conversation (called by `MemoryMaintainer`). `conversations`
    /// has a private setter, so the maintainer routes writes through here.
    func applySummary(conversationID id: UUID, summary: String, summarizedCount: Int) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].summary = summary
        conversations[idx].summarizedCount = summarizedCount
    }

    /// One derived stress line for the coach context: the Baevsky Stress Index over TODAY's R-R, read
    /// via the store exactly as `StressView` does (`storeHandle()` → `rrIntervals(deviceId:from:to:)`),
    /// then summarised to a single number with `StressIndex.stressIndex(rr:)`. Returns nil when the
    /// store is unavailable or there are too few clean beats (the histogram needs >= 20), so the line is
    /// simply absent, never a fabricated value. Summary-only: the raw R-R never leaves the device.
    func stressIndexLine() async -> String? {
        let cal = Calendar.current
        let from = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        guard let store = await repo.storeHandle() else { return nil }
        let rr = (try? await store.rrIntervals(
            deviceId: repo.deviceId, from: from, to: to, limit: 200_000)) ?? []
        guard let si = StressIndex.stressIndex(rr: rr) else { return nil }
        var line = Self.stressIndexSummary(si: si)

        // Hourly history alongside the single number, the SAME per-hour proxy the Stress screen's
        // timeline shows (`DaytimeStress.analyze`) — so the coach can say WHEN today ran high, not just
        // by how much overall.
        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        let tz = TimeZone.current.secondsFromGMT(for: Date())
        let daytime = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: tz)
        if let daytimeLine = Self.daytimeStressLine(daytime) { line += "\n" + daytimeLine }
        return line
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index over today's R-R; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// Pure formatter for the hourly daytime-stress history: nil once nothing scored yet today (too
    /// little HR — same gate `DaytimeStress` applies), otherwise each scored hour's 0–3 level, the peak
    /// hour, and a sustained-high call-out when the most recent scored hours all sit in the HIGH band.
    nonisolated static func daytimeStressLine(_ result: DaytimeStress.Result) -> String? {
        let scored = result.scored
        guard !scored.isEmpty else { return nil }
        let points = scored.map { String(format: "%02d:00 %.1f", $0.hour, $0.level ?? 0) }
            .joined(separator: ", ")
        var line = "Daytime stress (hourly, 0-3 proxy): \(points)"
        if let peak = result.peak {
            line += String(format: "; peak %02d:00 (%.1f)", peak.hour, peak.level ?? 0)
        }
        if result.sustainedHigh {
            line += "; sustained HIGH for the last \(result.sustainedRun) scored hours"
        }
        return line
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker), a personal dose-response read for dosed behaviours, and a one-line
    /// roll-up of their Lab Book markers. Plain sentences, never raw readings: this rides the same text
    /// channel as the metrics summary, so the no-raw-egress posture holds. Gated by the caller on the
    /// second opt-in; returns "" when there's nothing worth adding. `limit` caps the correlation list
    /// (the `get_personal_patterns` tool parameter), not the dose-response section (at most one line per
    /// `DosedBehavior` case).
    func onDeviceSignalsBlock(limit: Int = 3) async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        var byBehaviour: [String: Set<String>] = [:]
        for e in entries where e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
        let recoveryByDay = Dictionary(
            repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
            uniquingKeysWith: { _, last in last })
        if !byBehaviour.isEmpty {
            let ranked = EffectRanker.rank(behaviors: byBehaviour, outcomeByDay: recoveryByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(limit)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
        }

        // 1b. Personal dose-response (alcohol→Charge, caffeine→HRV): a prior-shrunk "each extra unit ≈
        // Δ for you" read once the user logs doses — the SAME engine + documented priors the Insights
        // Dose cards use (`InsightsHubViewModel.load`), reusing its dose-key/dose-source/matches helpers
        // so the two can't drift.
        let hrvByDay = Dictionary(
            repo.days.compactMap { d in d.avgHrv.map { (d.day, $0) } },
            uniquingKeysWith: { _, last in last })
        var doseRowsByBehavior: [DosedBehavior: [(day: String, value: Double)]] = [:]
        for behavior in DosedBehavior.allCases {
            let key = InsightsHubViewModel.doseKey(for: behavior)
            doseRowsByBehavior[behavior] = await repo.series(key: key, source: InsightsHubViewModel.doseSource)
        }
        let doseLines = Self.doseResponseLines(byBehaviour: byBehaviour, doseRowsByBehavior: doseRowsByBehavior,
                                               recoveryByDay: recoveryByDay, hrvByDay: hrvByDay)
        if !doseLines.isEmpty {
            lines.append("")
            lines.append("PERSONAL DOSE-RESPONSE (shrunk toward a documented prior until there's enough "
                         + "of the user's own data):")
            lines.append(contentsOf: doseLines)
        }

        // 2. Lab Book markers roll-up (count + latest of a few, never the full history).
        if let store = await repo.storeHandle() {
            var markerSummaries: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                let byKey = Dictionary(grouping: rows, by: { $0.markerKey })
                for (key, kRows) in byKey {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key)) \(latest.unit)" } ?? latest.valueText ?? "—"
                    markerSummaries.append("\(name) \(value)")
                }
            }
            if !markerSummaries.isEmpty {
                lines.append("")
                lines.append("LAB BOOK (the user's own logged health numbers — not medical advice; do not interpret as clinical findings):")
                lines.append("  " + markerSummaries.prefix(8).joined(separator: ", "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Pure core for the dose-response section of `onDeviceSignalsBlock`: given the journal's yes-day
    /// map, each dosed behaviour's explicit dose rows, and the two outcome series it might shrink
    /// against, returns one line per behaviour with enough dose data to produce an estimate. Kept
    /// separate from the `repo`/store reads that gather its inputs so it's independently testable.
    static func doseResponseLines(byBehaviour: [String: Set<String>],
                                  doseRowsByBehavior: [DosedBehavior: [(day: String, value: Double)]],
                                  recoveryByDay: [String: Double], hrvByDay: [String: Double]) -> [String] {
        var doseLines: [String] = []
        for behavior in DosedBehavior.allCases {
            var doses: [String: Int] = [:]
            for (question, days) in byBehaviour where InsightsHubViewModel.matches(behavior, question: question) {
                for day in days { doses[day] = max(doses[day] ?? 0, 1) }
            }
            for row in (doseRowsByBehavior[behavior] ?? []) { doses[row.day] = Int(row.value.rounded()) }
            guard !doses.isEmpty else { continue }
            let outcomeByDay = DoseResponsePriors.defaultOutcome(for: behavior) == "HRV" ? hrvByDay : recoveryByDay
            guard let response = DoseResponseEngine.estimate(
                behavior: behavior, doseByDay: doses, outcomeByDay: outcomeByDay) else { continue }
            doseLines.append("  • \(behavior.rawValue.capitalized): " + response.sentence())
        }
        return doseLines
    }

    /// Dispatch to the user's chosen provider client. When tool-calling is active (data consent on and a
    /// tool-capable provider such as Anthropic), run the tool-use loop so the model pulls the user's real
    /// numbers on demand; otherwise fall back to the plain single-shot text path.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> CoachToolReply {
        if toolCallingActive, let toolClient = provider.client as? ToolCallingClient {
            return try await toolClient.sendWithTools(
                key: key,
                model: requestModel,
                systemPrompt: systemPrompt,
                messages: messages,
                tools: coachTools,
                runTool: { [weak self] name, input in
                    await self?.runCoachTool(name, input: input) ?? ""
                },
                session: session
            )
        }
        let text = try await provider.client.send(
            key: key,
            model: requestModel,
            systemPrompt: systemPrompt,
            messages: messages,
            session: session
        )
        return CoachToolReply(text: text, toolsUsed: [])
    }

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent history that fits the model's token budget, dropping the middle. Sending the whole growing
    /// history crowds out the reply on small-context local servers (Ollama defaults to a 2048-token
    /// window, the Custom provider's main use case) and balloons token cost/latency on cloud providers.
    ///
    /// The size is a TOKEN BUDGET (`CoachHistoryBudget`), not the flat 10-message count it used to be —
    /// that one number treated a 2 048-token local model and a 200 000-token Claude identically. The old
    /// count survives as a floor (`minMessages`), so no provider ends up with less context than before;
    /// a large model simply gets more when the turns are short. (Android still uses the flat count; this
    /// is a fork-side divergence, and the floor keeps the two agreeing on the small-model case.)
    private func windowedMessages() -> [ChatMessage] {
        // `requestModel`, not `model`: a deep re-run may go to a model with a different context window,
        // and the window has to match the model the request is actually sent to.
        Self.windowedMessages(
            messages,
            budgetTokens: CoachHistoryBudget.tokens(provider: provider, model: requestModel))
    }

    /// Static and pure so the windowing is unit-testable without an engine or a provider.
    static func windowedMessages(_ messages: [ChatMessage], budgetTokens: Int) -> [ChatMessage] {
        guard messages.count > CoachHistoryBudget.minMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }

        // Walk backwards from the newest turn, taking messages while the budget holds. The floor is
        // applied afterwards, so a budget too small to fit even that many still sends them — being
        // stricter than the previous build would be a regression, not a fix.
        var used = 0
        var keep = 0
        for message in messages.reversed() {
            let cost = CoachHistoryBudget.estimateTokens(message.text)
            if keep > 0 && used + cost > budgetTokens { break }
            used += cost
            keep += 1
        }
        keep = min(messages.count, max(keep, CoachHistoryBudget.minMessages))
        if keep == messages.count { return messages }

        let recentStart = messages.count - keep
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(keep)) }
        return [messages[firstUser]] + Array(messages[recentStart...])
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    /// The facts most relevant to the CURRENT question are folded into that context (pinned facts already
    /// ride the system prompt), so memory scales without every prompt carrying all 40 facts.
    /// Chart-host messages (`flushPendingCharts` appends an empty assistant turn per chart) never go on
    /// the wire: Anthropic rejects empty content, so a follow-up question after a chart would 400.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        let question = messages.last(where: { $0.role == .user })?.text ?? ""
        let relevant = CoachMemory.shared.relevantBlock(for: question, limit: 8)
        let fullContext = relevant.isEmpty ? context : context + "\n\n" + relevant
        return Self.wirePairs(from: windowedMessages(), context: fullContext)
    }

    /// Pure: fold the windowed transcript into wire pairs. Split from `wireMessages` so the
    /// empty-turn filter is unit-testable without an engine instance.
    ///
    /// The context rides the LAST user turn (the actual question), not the first: it's all behind the
    /// system-block cache breakpoint, so anchoring it later costs nothing, and the living plan block ends
    /// up next to the question the user just asked instead of ten messages back. When `context` is blank
    /// (the tool path with no pending proposals — the stable prose now lives in the cached system block),
    /// the question is sent ALONE: no `\n\n---\n\nQuestion:` scaffold wrapped around nothing.
    nonisolated static func wirePairs(from windowed: [ChatMessage], context: String) -> [(role: ChatMessage.Role, content: String)] {
        let anchorIndex = windowed.lastIndex(where: { $0.role == .user && !$0.text.isEmpty })
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [(role: ChatMessage.Role, content: String)] = []
        for (i, m) in windowed.enumerated() {
            if m.text.isEmpty { continue }
            if i == anchorIndex && !ctx.isEmpty {
                out.append((.user, context + "\n\n---\n\nQuestion: " + m.text))
            } else {
                out.append((m.role, m.text))
            }
        }
        return out
    }

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = [clockLine(), "", "USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        // Profile + goal (NOOP AI): the same values the app's HR zones and calorie math use, so the
        // coach can prescribe zones/loads for THIS user. Consent-gated like the rest — buildContext()
        // is only reached with data access on.
        let profile = ProfileStore()
        var profileParts = ["age \(profile.age)", profile.sex,
                            "\(Int(profile.weightKg.rounded())) kg",
                            "\(Int(profile.heightCm.rounded())) cm",
                            "HRmax \(profile.hrMax) bpm"]
        lines.append("Profile: " + profileParts.joined(separator: ", "))
        // The goal as a REAL goal: weeks remaining, required change, phase, and the safety verdict —
        // not the bare sentence the old free-text field could only offer.
        if let goalsBlock = goalsBlock(profile: profile) { lines.append(goalsBlock) }

        guard !days.isEmpty else {
            // Keep the profile/goal line (already appended) so the coach can still personalise zones
            // and advice while there's no wearable history yet.
            lines.append("No wearable data is available yet. Acknowledge this and give general, "
                         + "encouraging guidance while inviting the user to sync their device so future "
                         + "advice can reference real numbers.")
            return lines.joined(separator: "\n")
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        lines.append("")
        lines.append("Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), HRV(ms), RHR(bpm):")
        for d in recent {
            lines.append("  " + dayLine(d))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  charge: \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")
        if let vo2max = estimatedVO2max(days: days, profile: profile) {
            lines.append(String(format: "Estimated VO2max: %.1f ml/kg/min", vo2max))
        }

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        var lines: [String] = []
        if let mostRecent = rows.first {
            let n = daysAgo(mostRecent.startTs)
            let ago = n <= 0 ? "today" : (n == 1 ? "1 day ago" : "\(n) days ago")
            lines.append("Last trained: \(ago) (\(mostRecent.sport)).")
        }
        lines.append("Recent workouts (newest first):")
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM { parts.append("\(String(format: "%.1f", dist / 1000)) km") }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    private func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
        parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
