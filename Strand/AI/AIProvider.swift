import Foundation

// MARK: - Provider enum

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case gemini
    case openRouter
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:     return "OpenAI"
        case .anthropic:  return "Anthropic"
        case .gemini:     return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .custom:     return "Custom (OpenAI-compatible)"
        }
    }

    /// The default CHAT (coaching) model — the one that runs the actual conversation. Deliberately a
    /// STRONG model per provider, not a mini/flash one (#P4 5.6): the coach's whole value is the quality
    /// of its reasoning over the user's data, so a weak default would make the first experience feel bad
    /// for no reason the user chose. Cheap models have their own role (`cheapModel`, summary/card work).
    var defaultModel: String {
        switch self {
        case .openAI:     return "gpt-4o"
        case .anthropic:  return "claude-sonnet-4-6"
        case .gemini:     return "gemini-pro-latest"   // stable alias → current Pro, no version churn (#400)
        case .openRouter: return "anthropic/claude-sonnet-4.6"
        case .custom:     return ""   // the user picks the model their server serves
        }
    }

    /// A cheap, fast model for BACKGROUND work — summarising chats into memory, and short one-off card
    /// analyses — that shouldn't burn the pricier coaching model. This is the default for the `.summary`
    /// and `.cardAnalysis` roles (see `CoachModelRole`). Empty for Custom (falls back to the user's model).
    var cheapModel: String {
        switch self {
        case .openAI:     return "gpt-4o-mini"
        case .anthropic:  return "claude-haiku-4-5-20251001"
        case .gemini:     return "gemini-flash-lite-latest"
        case .openRouter: return "openai/gpt-4o-mini"
        case .custom:     return ""
        }
    }

    /// The built-in default model for a given ROLE. `.chat` gets the strong `defaultModel`; the cheaper
    /// background roles (`.summary`, `.cardAnalysis`) share `cheapModel`. The engine's `model(for:)`
    /// resolver layers the user's own per-role override (and a chat-model fallback) on top of this.
    func defaultModel(for role: CoachModelRole) -> String {
        switch role {
        case .chat:                     return defaultModel
        case .summary, .cardAnalysis:   return cheapModel
        // No built-in default ON PURPOSE. Every other role can be defaulted because the app knows what
        // it wants — strong for chat, cheap for background work. "Deeper" has no such answer: which
        // model is worth its price is the user's call, and picking one for them would silently move a
        // question onto a model they never chose. Empty ⇒ `hasDeepAnalysisModel` is false ⇒ the UI
        // never offers it.
        case .deepAnalysis:             return ""
        }
    }

    /// Models offered in the picker. A "Custom…" path in the UI lets the user pick any id beyond
    /// these, and `refreshModels()` can merge the provider's live list.
    var modelOptions: [String] {
        switch self {
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"]
        case .anthropic:
            return [
                "claude-opus-4-8",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-3-7-sonnet-latest",
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest",
                "claude-3-opus-latest"
            ]
        case .gemini:
            // Stable `-latest` ALIASES, not pinned versions (#400): they always resolve to the current
            // stable model in each tier, so Gemini's rapid releases never need a code bump. `refreshModels()`
            // still merges the live `/models` catalogue, so a user with a key can pin a concrete version.
            return [
                "gemini-pro-latest",
                "gemini-flash-latest",
                "gemini-flash-lite-latest"
            ]
        case .openRouter:
            // A small, currently-valid starting handful (verified against the live catalogue, not
            // guessed) — a `vendor/slug` id per vendor. `refreshModels()` pulls the other 300+ from the
            // real catalogue; this list will drift over time exactly like the three above already do.
            return [
                "anthropic/claude-sonnet-4.6",
                "openai/gpt-4o-mini",
                "google/gemini-2.5-flash",
                "deepseek/deepseek-chat",
                "meta-llama/llama-3.3-70b-instruct"
            ]
        case .custom:
            return []   // populated from the server's /models (refreshModels) or typed in
        }
    }

    var endpoint: URL {
        switch self {
        case .openAI:     return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic:  return URL(string: "https://api.anthropic.com/v1/messages")!
        case .gemini:     return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .custom:     return AIProvider.customURL(path: "/chat/completions")
        }
    }

    var modelsEndpoint: URL {
        switch self {
        case .openAI:     return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic:  return URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:     return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/models")!
        case .custom:     return AIProvider.customURL(path: "/models")
        }
    }

    var client: any AIProviderClient {
        switch self {
        case .openAI:     return OpenAIClient()
        case .anthropic:  return AnthropicClient()
        case .gemini:     return GeminiClient()
        case .openRouter: return OpenRouterClient()
        case .custom:     return CustomClient()
        }
    }

    // MARK: - Custom (OpenAI-compatible) base URL

    /// UserDefaults key for the Custom provider's base URL (e.g. a local LLM server such as Ollama /
    /// LM Studio / llama.cpp: `http://localhost:11434/v1`). `AICoachEngine` exposes it for editing.
    static let customBaseURLKey = "ai.customBaseURL"

    /// The user-set Custom base URL, trimmed.
    static var customBaseURL: String {
        (UserDefaults.standard.string(forKey: customBaseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build a Custom endpoint by appending `path` to the user's base URL (trailing slashes tolerated).
    /// Falls back to a loopback placeholder when unset — the request then fails with a clear network
    /// error until the user sets a URL.
    static func customURL(path: String) -> URL {
        var base = customBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? URL(string: "http://localhost" + path)!
    }

    /// #321 gatekeeper for the Custom (local LLM) provider — the byte-parity twin of Android
    /// `AiCoach.guardCustomUrl` (#187), which Swift was previously missing. `https://` is always fine;
    /// plain `http://` is allowed ONLY to a private-network host (loopback / RFC-1918 / link-local /
    /// `*.local`), so a public cleartext endpoint can never egress. Throws `AICoachError.badCustomURL`
    /// with an actionable message on rejection. Called by `CustomClient.send` + `fetchModels`, i.e. on
    /// BOTH Custom network paths (mirrors Kotlin `customChatUrl` / `customModelsUrl`).
    static func guardCustomBaseURL() throws {
        let base = customBaseURL   // already trimmed / trailing-slash-stripped by the accessor
        guard let comps = URLComponents(string: base),
              let host = comps.host, !host.isEmpty,
              let scheme = comps.scheme?.lowercased(), !scheme.isEmpty else {
            throw AICoachError.badCustomURL(
                "That server URL isn't valid. Use http://<host>:<port> for a local server, or https://… for a remote one.")
        }
        if scheme == "https" { return }
        guard scheme == "http" else {
            throw AICoachError.badCustomURL(
                "Unsupported URL scheme \"\(scheme)\". Use http:// for a local server or https:// for a remote one.")
        }
        guard isPrivateLANOrLoopback(host) else {
            throw AICoachError.badCustomURL(
                "Plain http:// is only allowed to a local-network server (localhost, 10.x, 172.16-31.x, "
                + "192.168.x, 169.254.x, or a .local name). Use https:// to reach \"\(host)\".")
        }
    }

    /// True when `host` is on the device's own machine or its private LAN, so plain `http://` to it never
    /// crosses the public internet: loopback (localhost / 127.0.0.0/8 / ::1), RFC-1918 (10/8, 172.16/12,
    /// 192.168/16), link-local (169.254/16 / fe80::/10), fc00::/7 ULA, and any `*.local` mDNS name.
    /// Byte-identical decisions to Android `AiCoach.isPrivateLanOrLoopback`.
    static func isPrivateLANOrLoopback(_ host: String) -> Bool {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)   // match Kotlin String.trim()
        let h = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h.isEmpty { return false }
        // Only apply the fc/fd/fe80 classification to a real IPv6 LITERAL (bracketed, or contains a colon),
        // so a public NAME like "fclient.evil.com" can't be mistaken for a ULA and allowed cleartext.
        let isIPv6Literal = raw.hasPrefix("[") || h.contains(":")
        if isIPv6Literal {
            if h == "::1" { return true }
            if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:") { return true }
            return false
        }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h.hasSuffix(".local") && h.count > ".local".count { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count != 4 { return false }
        let octets = parts.map { Int($0) ?? -1 }
        if octets.contains(where: { $0 < 0 || $0 > 255 }) { return false }
        let a = octets[0], b = octets[1]
        switch true {
        case a == 127: return true                       // 127.0.0.0/8 loopback
        case a == 10: return true                        // 10.0.0.0/8
        case a == 172 && (16...31).contains(b): return true  // 172.16.0.0/12
        case a == 192 && b == 168: return true           // 192.168.0.0/16
        case a == 169 && b == 254: return true           // 169.254.0.0/16 link-local
        default: return false
        }
    }
}

// MARK: - Model roles

/// Which job a model does for the coach. The coach isn't one model — it's a few, matched to the work:
///
///  - `.chat` — the actual coaching conversation. Wants the strongest model (see `defaultModel`).
///  - `.summary` — distilling a finished chat into a short memory the coach can recall later. Runs in
///    the background, needs far less model quality than a live conversation, so it defaults to a cheap
///    one. (This is the role the pre-existing "memory model" setting configures.)
///  - `.cardAnalysis` — a short, cautious read of ONE health card (opened from that card). Also a small,
///    bounded job, so it too defaults to the cheap model. (Consumed by the card-AI feature.)
///
/// Splitting these lets a user spend on the conversation while keeping the background/quick work cheap —
/// a concrete cost lever, not a preference. The engine's `model(for:)` resolves each role to the user's
/// own override if set, else the provider's per-role default, else the chat model (so a role is never
/// left pointing at nothing).
enum CoachModelRole: String, CaseIterable, Identifiable {
    case chat
    case summary
    case cardAnalysis
    /// A deliberately heavier model for one question the user wants gone into properly — a training
    /// plan, a months-long trend, a plan rework.
    ///
    /// Depth is expressed as a MODEL, not as a "thinking" flag, and that is the whole design. With free
    /// model choice (OpenRouter fronts 300+), a reasoning parameter is silently ignored by roughly half
    /// of them, so the same switch would deepen one model and do nothing at all for the next — behaviour
    /// nobody can explain to a user. A second model always differs, on every provider, including ones
    /// with no reasoning support whatsoever. It also keeps the cost honest: the user picked the
    /// expensive model themselves and asked for it per question, so nothing silently multiplies a price
    /// they chose. Unset ⇒ the affordance doesn't appear at all.
    case deepAnalysis

    var id: String { rawValue }

    /// UserDefaults key holding the user's override for this role, or nil for `.chat` (whose model is the
    /// primary `ai.model` selection, not a separate override). `.summary` reuses the pre-existing
    /// `ai.memoryModel` key so no user loses the memory model they already configured.
    var overrideDefaultsKey: String? {
        switch self {
        case .chat:         return nil
        case .summary:      return "ai.memoryModel"
        case .cardAnalysis: return "ai.cardModel"
        case .deepAnalysis: return "ai.deepModel"
        }
    }
}

// MARK: - Provider protocol

protocol AIProviderClient {
    /// Send a chat turn and return the assistant reply text.
    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String

    /// Fetch the provider's live model list and return plain model ids.
    func fetchModels(key: String, session: URLSession) async throws -> [String]
}

// MARK: - Shared HTTP helpers

/// Execute a request, map HTTP status codes to `AICoachError`, return the decoded JSON object.
func performRequest(_ req: URLRequest, session: URLSession) async throws -> [String: Any] {
    let data: Data
    let response: URLResponse

    do {
        (data, response) = try await session.data(for: req)
    } catch {
        throw coachTransportError(error)
    }

    guard let http = response as? HTTPURLResponse else {
        throw AICoachError.network("no HTTP response")
    }

    switch http.statusCode {
    case 200...299:
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AICoachError.decode
        }

        return obj
    case 401, 403:
        throw AICoachError.badKey
    case 429:
        throw AICoachError.rateLimited(retryAfter: retryAfterSeconds(http))
    default:
        throw AICoachError.server(http.statusCode, providerErrorMessage(from: data))
    }
}

/// Classify a transport failure. Being offline is its own case: forwarding `localizedDescription`
/// showed the user CFNetwork prose ("The Internet connection appears to be offline.") wrapped in a
/// "Network problem:" prefix, when the honest answer is one sentence and a different next step —
/// retrying immediately cannot work. Cancellation is left as-is for callers to detect (a user Stop).
func coachTransportError(_ error: Error) -> AICoachError {
    guard let urlError = error as? URLError else {
        return AICoachError.network(error.localizedDescription)
    }
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
         .internationalRoamingOff, .cannotConnectToHost, .cannotFindHost:
        return .offline
    default:
        return .network(urlError.localizedDescription)
    }
}

/// Seconds from a 429's `Retry-After`. The header is either a delay in seconds or an HTTP date;
/// both are accepted, and a date in the past clamps to nil rather than a negative countdown.
func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
    guard let raw = (response.value(forHTTPHeaderField: "Retry-After")
                        ?? response.value(forHTTPHeaderField: "retry-after"))?
        .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let seconds = Int(raw) { return seconds > 0 ? seconds : nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: raw) else { return nil }
    let delta = Int(date.timeIntervalSinceNow.rounded())
    return delta > 0 ? delta : nil
}

/// Best-effort extraction of a human-readable message from a provider error body.
func providerErrorMessage(from data: Data) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

    if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
    if let msg = obj["message"] as? String { return msg }

    return ""
}
