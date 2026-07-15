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
    let id: UUID
    let role: Role
    let text: String
    /// When the turn was created — drives time separators in the transcript. Defaulted on decode so
    /// transcripts saved before this field existed still load (they just show "now" for old turns).
    let date: Date

    init(id: UUID = UUID(), role: Role, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
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
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
enum AICoachError: LocalizedError {
    case noKey
    case emptyQuestion
    case badKey
    case rateLimited
    case server(Int, String)
    case network(String)
    case decode
    case keySaveFailed
    case badCustomURL(String)

    var errorDescription: String? {
        switch self {
        case .badCustomURL(let message):
            return message
        case .noKey:
            return "Add your own API key first to use the coach."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited:
            return "The provider is rate-limiting requests right now. Wait a moment and try again."
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
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
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
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    HRV, resting heart rate) and recent workouts. Charge is the daily recovery/readiness score, effort \
    is the daily cardiovascular load score, and rest is the nightly sleep-quality score. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67-100 = green light to build/push, higher effort is fine; \
    34-66 = maintain, quality over volume, keep it controlled; 0-33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating - like a coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor - never diagnose; suggest a professional for genuine health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans, ### headings only when structure genuinely helps, and a \
    small table only for a week-ahead plan. No code blocks.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (stored?.isEmpty == false) ? stored! : Self.defaultSystemPrompt
        // The selected persona sets the coach's VOICE on top of the methodology in `base`, so
        // the tone changes while the coaching logic and guardrails stay intact. Read fresh so a
        // persona switch applies to the very next message, like the prompt itself.
        var prompt = persona.systemPreamble + "\n\n" + base
        // Persistent memory: the user's goal + facts the model saved via `remember_fact`. Read fresh
        // so a fact remembered THIS turn frames the very next one.
        let memory = CoachMemory.shared.promptBlock
        if !memory.isEmpty { prompt += "\n\n" + memory }
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

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)

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
    }

    /// Debounced transcript persistence (see init).
    private var transcriptAutosave: AnyCancellable?

    // MARK: Conversation management (history)

    /// Start a new conversation and switch to it. If the active one is already empty, reuse it rather
    /// than piling up blank threads. Preserved name `clearChat` as an alias so old call sites still work.
    func newConversation() {
        if let cur = activeConversation, cur.messages.isEmpty {
            chartsByMessage = [:]
            errorText = nil
            return
        }
        let fresh = CoachConversation()
        conversations.insert(fresh, at: 0)
        activeConversationID = fresh.id
        chartsByMessage = [:]
        errorText = nil
    }

    /// Back-compat alias for the old "New chat" button.
    func clearChat() { newConversation() }

    /// Switch the visible chat to another saved conversation, restoring its charts.
    func switchTo(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        activeConversationID = id
        errorText = nil
        rebuildChartsForActive()
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
        sendTask = Task { [weak self] in await self?.send(text) }
    }

    /// Stop an in-flight reply. Whatever streamed so far stays in the transcript; no error is shown.
    func stop() {
        sendTask?.cancel()
        sendTask = nil
        sending = false
    }

    /// Regenerate the last reply: drop everything back to (and including) the last user turn, purge any
    /// charts those dropped messages hosted, then resend that same question.
    func regenerate() {
        guard !sending, let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
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

    /// True when a key is present in the Keychain.
    var hasKey: Bool { AIKeyStore.read() != nil }

    /// True once the coach can actually send: a stored key for the cloud providers, or, for the
    /// Custom (local) provider, a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`.
    private var resolvedKey: String? {
        if let k = AIKeyStore.read() {
            // Only send the stored key to the provider it was SAVED for, never Bearer one provider's
            // key (e.g. a cloud OpenAI/Anthropic secret) to another provider's endpoint, above all the
            // arbitrary user-typed Custom URL. A legacy key with no recorded owner is assumed to belong
            // to a cloud provider, so it is never auto-sent to Custom.
            let owner = AIKeyStore.ownerProvider
            if owner == provider.rawValue { return k }
            if owner == nil && provider != .custom { return k }
        }
        return provider == .custom ? "" : nil
    }

    /// Commit the Custom (local) provider once the user has entered a server URL. Optionally stores a
    /// key first if they pasted one. Pulls the server's live model list so the picker isn't empty.
    func connectCustom() {
        let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        errorText = nil
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

    /// Disconnect entirely: forget any stored key and un-commit the Custom provider. The base URL is
    /// kept so reconnecting pre-fills it.
    func disconnect() {
        AIKeyStore.clear()
        customConnected = false
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
        errorText = nil
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET
        // egresses to the provider the MOMENT a key is saved (IP + request timing + key-validity) — before
        // any send, in an app that is zero-network by default. The picker shows the curated models; the LIVE
        // list is pulled only when the user taps Refresh (an explicit action that is its own consent) or
        // sends. Local Custom servers still refresh on Connect.
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
    #endif

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        guard let key = resolvedKey else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        errorText = nil

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                errorText = AICoachError.decode.errorDescription
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
        } catch {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
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

        errorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        sending = true
        defer { sending = false }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        // In tool-calling mode we send a lean note and let the model FETCH the data it needs via tools,
        // instead of pre-baking the whole summary into the prompt.
        let context = toolCallingActive
            ? Self.toolModeContextNote
            : (dataConsent ? await buildFullContext() : noConsentNote)
        let wire = wireMessages(context: context)

        // Streaming path when the provider supports it (Anthropic): the reply appears token-by-token in
        // a live-growing assistant bubble. Any tool rounds run inline. Other providers keep the plain
        // single-shot path below, unchanged.
        if let streamer = provider.client as? StreamingToolClient {
            let replyId = UUID()
            messages.append(ChatMessage(id: replyId, role: .assistant, text: ""))
            do {
                _ = try await streamer.streamWithTools(
                    key: key,
                    model: model,
                    systemPrompt: systemPrompt,
                    messages: wire,
                    tools: toolCallingActive ? coachTools : [],
                    runTool: { [weak self] name, input in
                        await self?.runCoachTool(name, input: input) ?? ""
                    },
                    onDelta: { [weak self] delta in self?.appendDelta(delta, to: replyId) },
                    session: session
                )
                // An empty reply shows "(no reply)" — unless the turn produced a chart, in which case we
                // drop the blank bubble and let the chart (flushed below) stand on its own.
                if let idx = messages.firstIndex(where: { $0.id == replyId }), messages[idx].text.isEmpty {
                    if pendingCharts.isEmpty {
                        messages[idx] = ChatMessage(id: replyId, role: .assistant, text: "(no reply)")
                    } else {
                        messages.remove(at: idx)
                    }
                }
                flushPendingCharts()
            } catch let e as AICoachError {
                removeAssistantIfEmpty(replyId); discardPendingCharts(); errorText = e.errorDescription
            } catch {
                // A user-initiated Stop cancels the task; keep whatever streamed so far, show no error.
                if Self.isCancellation(error) {
                    flushPendingCharts()
                } else {
                    removeAssistantIfEmpty(replyId); discardPendingCharts()
                    errorText = AICoachError.network(error.localizedDescription).errorDescription
                }
            }
            return
        }

        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: .assistant, text: clean.isEmpty ? "(no reply)" : clean))
            flushPendingCharts()
        } catch let e as AICoachError {
            discardPendingCharts(); errorText = e.errorDescription
        } catch {
            discardPendingCharts()
            if !Self.isCancellation(error) {
                errorText = AICoachError.network(error.localizedDescription).errorDescription
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
    func handlePlotMetric(metric: String, days: Int) -> String {
        guard let art = chartArtifact(metric: metric, days: days) else {
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
    /// the engine rather than in the tool extension. Returns nil for an unknown metric or too little data.
    private func chartArtifact(metric rawMetric: String, days: Int) -> CoachChartArtifact? {
        let n = max(7, min(days, 180))
        let recent = Array(repo.days.suffix(n))
        guard !recent.isEmpty else { return nil }

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
            return nil
        }

        guard points.count >= 2 else { return nil }
        return CoachChartArtifact(title: title, points: points, valueRange: range, kind: kind)
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

    /// `get_sleep_detail`: per-night stages/efficiency from the daily roll-up plus the rolling
    /// 14-night sleep-debt ledger (`SleepDebt.ledger`). Summary text only, never raw samples.
    func sleepDetailTool(nights: Int) async -> String {
        let n = max(1, min(nights, 14))
        let all = repo.days
        let recent = Array(all.suffix(n))
        guard !recent.isEmpty else { return "No sleep data recorded yet." }

        var lines = ["SLEEP DETAIL (newest first) — asleep(h), efficiency(%), deep/REM/light(min), disturbances, RHR, HRV:"]
        for d in recent.reversed() {
            var parts = ["  \(d.day):"]
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

        // Rolling sleep-debt ledger over the last 30 nights (14-night window inside the engine).
        let ledger = SleepDebt.ledger(series: all.suffix(30).map { ($0.day, $0.totalSleepMin) })
        if !ledger.nights.isEmpty {
            let bal = ledger.balanceMin / 60
            let need = ledger.needMin / 60
            lines.append("")
            lines.append(String(format: "Sleep debt (rolling %d nights vs a %.1fh need): %+.1fh %@",
                                ledger.nights.count, need, bal,
                                bal < 0 ? "(deficit — behind on sleep)" : "(surplus)"))
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
    func startBriefIfNeeded() async {
        guard messages.isEmpty else { return }
        await generateBrief()
    }

    /// Force a fresh "Today's brief" even mid-conversation — used when the user taps the daily check-in
    /// notification, so tapping always surfaces an up-to-date brief rather than an old one.
    func refreshBrief() async {
        await generateBrief()
    }

    /// Shared brief generation: build today's context and ask the provider for the three-part brief.
    /// Gated on a key + data consent; `!sending` prevents overlapping a brief with an in-flight message.
    private func generateBrief() async {
        guard isConfigured, dataConsent, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false }

        let context = toolCallingActive ? Self.toolModeContextNote : await buildFullContext()
        let instruction = """
        Based on the data above, give me TODAY'S coaching brief in three short parts: \
        (1) my readiness in one line, citing charge, HRV and rest; \
        (2) exactly what training to do today and what to avoid; \
        (3) one specific thing to improve my charge. Be punchy and motivating.
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, context + "\n\n---\n\n" + instruction)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: "Today's brief\n\n" + clean))
            }
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    func buildFullContext() async -> String {
        var ctx = buildContext()
        ctx += "\n\n" + (await recentWorkoutsBlock())
        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Gated here under `dataConsent` (the caller only reaches buildFullContext()
        // with consent on), so it rides the SAME consent + text-only channel as the HRV/RHR summary, a
        // derived number, never raw R-R egress. Omitted when there aren't enough clean beats yet.
        if let line = await stressIndexLine() { ctx += "\n\n" + line }
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { ctx += "\n\n" + block }
        }
        return ctx
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
        return Self.stressIndexSummary(si: si)
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index over today's R-R; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        var byBehaviour: [String: Set<String>] = [:]
        for e in entries where e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, outcomeByDay: outcomeByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(3)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
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

    /// Dispatch to the user's chosen provider client. When tool-calling is active (data consent on and a
    /// tool-capable provider such as Anthropic), run the tool-use loop so the model pulls the user's real
    /// numbers on demand; otherwise fall back to the plain single-shot text path.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        if toolCallingActive, let toolClient = provider.client as? ToolCallingClient {
            return try await toolClient.sendWithTools(
                key: key,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                tools: coachTools,
                runTool: { [weak self] name, input in
                    await self?.runCoachTool(name, input: input) ?? ""
                },
                session: session
            )
        }
        return try await provider.client.send(
            key: key,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            session: session
        )
    }

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent `maxHistoryMessages`, dropping the middle. Sending the whole growing history crowds out the
    /// reply on small-context local servers (Ollama defaults to a 2048-token window, the Custom
    /// provider's main use case) and balloons token cost/latency on cloud providers. (parity with Android)
    private static let maxHistoryMessages = 10
    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        return [messages[firstUser]] + Array(messages[recentStart...])
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        for m in windowedMessages() {
            if m.role == .user && !contextInjected {
                contextInjected = true
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
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        // Profile + goal (NOOP AI): the same values the app's HR zones and calorie math use, so the
        // coach can prescribe zones/loads for THIS user. Consent-gated like the rest — buildContext()
        // is only reached with data access on.
        let profile = ProfileStore()
        var profileParts = ["age \(profile.age)", profile.sex,
                            "\(Int(profile.weightKg.rounded())) kg",
                            "\(Int(profile.heightCm.rounded())) cm",
                            "HRmax \(profile.hrMax) bpm"]
        let goal = CoachMemory.shared.trainingGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { profileParts.append("training goal: \(goal)") }
        lines.append("Profile: " + profileParts.joined(separator: ", "))

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

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        var lines = ["Recent workouts (newest first):"]
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
