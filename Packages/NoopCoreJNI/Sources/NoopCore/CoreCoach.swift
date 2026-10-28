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
        let coach = await engine(reader: reader, settings: CoreGoalEnergy.settings(args))
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
}
