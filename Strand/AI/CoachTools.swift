import Foundation

/// Tool-calling for the coach. Instead of pre-baking one fixed text block into every request, the
/// model is offered TOOLS it can call to pull the user's own metrics on demand — so it reasons about
/// what it needs (workouts for a training question, stress for a stress question) and answers with
/// real numbers. Each tool maps to an existing, privacy-preserving summary on `AICoachEngine`; no raw
/// readings ever leave the device. Kept in its own file so it stays merge-clean against upstream, and
/// only used for providers that advertise `ToolCallingClient` (Anthropic today).
enum CoachTool: String, CaseIterable {
    /// Recent-days table + 30-day averages of every core vital (charge, effort, rest, HRV, RHR, SpO₂…).
    case biometricSummary = "get_biometric_summary"
    /// The user's recent workouts, newest first — parameterised, so the model can ask for more than
    /// the summary's default handful.
    case recentWorkouts = "get_recent_workouts"
    /// Today's derived Baevsky Stress Index (autonomic-balance proxy over today's R-R).
    case stressIndex = "get_stress_index"
    /// The user's strongest n-of-1 patterns + Lab Book roll-up. Only offered when the second opt-in is on.
    case personalPatterns = "get_personal_patterns"

    /// Natural-language description the model reads to decide when to call the tool.
    var description: String {
        switch self {
        case .biometricSummary:
            return "Get the user's recent daily wearable metrics (last ~14 days plus 30-day averages): "
                + "charge/recovery, effort/strain, rest/sleep hours, HRV, resting HR, SpO2, respiration, "
                + "skin-temperature deviation, steps and active energy. Call this first for most questions."
        case .recentWorkouts:
            return "Get the user's recent workouts (newest first) with sport, duration, effort, average "
                + "heart rate, energy and distance. Use for training-load or workout questions."
        case .stressIndex:
            return "Get today's derived stress index (Baevsky Stress Index over today's R-R intervals); "
                + "higher means more sympathetic / under load. Use for stress or autonomic-balance questions."
        case .personalPatterns:
            return "Get the user's strongest personal patterns (their own n-of-1 correlations) and a "
                + "roll-up of their logged Lab Book health numbers. Use to explain what helps or hurts them."
        }
    }

    /// JSON Schema for the tool's input (Anthropic `input_schema`). Only `recentWorkouts` takes an argument.
    var inputSchema: [String: Any] {
        switch self {
        case .recentWorkouts:
            return [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "How many recent workouts to return (1–30). Defaults to 6."
                    ]
                ]
            ]
        default:
            return ["type": "object", "properties": [String: Any]()]
        }
    }

    /// Anthropic tool descriptor: `{ name, description, input_schema }`.
    var anthropicSpec: [String: Any] {
        ["name": rawValue, "description": description, "input_schema": inputSchema]
    }
}

// MARK: - Provider capability

/// A provider client that can run a tool-use loop. Providers opt in by conforming (see
/// `AnthropicClient`); the engine falls back to plain `send` for those that don't. Declared here
/// rather than in `AIProvider.swift` so tracking the upstream repo never conflicts on the protocol.
protocol ToolCallingClient {
    /// Run a multi-round tool-use conversation and return the final assistant text. `runTool` executes
    /// a tool call by name and returns a compact text result to feed back to the model.
    func sendWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [CoachTool],
        runTool: (String, [String: Any]) async -> String,
        session: URLSession
    ) async throws -> String
}

// MARK: - Engine: tool availability + execution

extension AICoachEngine {

    /// The tools offered to the model, honouring consent: the patterns/Lab Book tool only appears when
    /// the second opt-in is on, mirroring `buildFullContext`'s gating.
    var coachTools: [CoachTool] {
        var tools: [CoachTool] = [.biometricSummary, .recentWorkouts, .stressIndex]
        if includeOnDeviceSignals { tools.append(.personalPatterns) }
        return tools
    }

    /// True when the current turn should use the tool-use path: the user has granted data access, tools
    /// exist, and the chosen provider can run them. When false, the engine keeps the plain text-context path.
    var toolCallingActive: Bool {
        dataConsent && !coachTools.isEmpty && (provider.client is ToolCallingClient)
    }

    /// Short note sent in place of the pre-baked metrics context when tool-calling is active: it tells
    /// the model it must FETCH the user's real numbers via tools before advising, and never invent them.
    static let toolModeContextNote = """
    You have TOOLS to fetch the user's own wearable data on demand (biometric summary, recent workouts, \
    today's stress index, and — if shared — their personal patterns). Call the tools you need to ground \
    your answer in their REAL numbers before advising, and cite those numbers. If a tool reports no data, \
    say so plainly rather than inventing figures.
    """

    /// Execute one tool call and return a compact text result. Routes to the same consent-gated summaries
    /// the text-context path uses, so the no-raw-egress posture holds. Unknown names and missing-consent
    /// are reported as plain text so the model can recover gracefully.
    func runCoachTool(_ name: String, input: [String: Any]) async -> String {
        guard dataConsent else {
            return "The user has not granted data access, so their metrics are unavailable. "
                + "Coach generally and invite them to enable data access."
        }
        switch CoachTool(rawValue: name) {
        case .biometricSummary:
            return buildContext()
        case .recentWorkouts:
            let raw = (input["limit"] as? Int) ?? Int(input["limit"] as? Double ?? 6)
            let limit = max(1, min(raw, 30))
            return await recentWorkoutsBlock(limit: limit)
        case .stressIndex:
            return await stressIndexLine()
                ?? "Not enough clean R-R data today to compute a stress index yet."
        case .personalPatterns:
            guard includeOnDeviceSignals else {
                return "The user hasn't shared their patterns or Lab Book, so this isn't available."
            }
            let block = await onDeviceSignalsBlock()
            return block.isEmpty ? "No strong personal patterns have emerged yet." : block
        case .none:
            return "Unknown tool \"\(name)\"."
        }
    }
}
