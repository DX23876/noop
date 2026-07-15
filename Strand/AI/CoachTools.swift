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
    /// Draw a native chart of one metric over a day range directly in the chat (a visual artifact).
    case plotMetric = "plot_metric"
    /// Save a durable fact about the user to the coach's persistent memory (CoachMemory).
    case rememberFact = "remember_fact"
    /// Log a caffeine intake into the app's caffeine log (conversational logging).
    case logCaffeine = "log_caffeine"
    /// Log a daily journal behaviour (yes/no or numeric) into the app's journal.
    case logJournal = "log_journal"
    /// Log a Lab Book health marker (e.g. a blood value or supplement dose).
    case logLabMarker = "log_lab_marker"
    /// Per-night sleep detail: stages, efficiency, and the rolling sleep-debt ledger.
    case sleepDetail = "get_sleep_detail"
    /// A multi-week range report: per-metric stats + headline changes over 7–365 days.
    case rangeReport = "get_range_report"

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
        case .plotMetric:
            return "Draw a chart of one metric over time, shown directly in the chat. Use it when a "
                + "trend is easier to see than to describe. metric is one of charge, effort, hrv, rhr, sleep."
        case .rememberFact:
            return "Save one durable fact about the user to your persistent memory (goals, injuries, "
                + "schedule, preferences, constraints). Call it PROACTIVELY whenever the user shares "
                + "something worth remembering across conversations. One concise sentence per fact."
        case .logCaffeine:
            return "Log a caffeine intake for the user (e.g. they say they just had a coffee). "
                + "mg is optional — a single espresso is ~63 mg, a double ~125 mg, filter coffee ~95 mg, "
                + "black tea ~47 mg, cola ~33 mg, energy drink ~80 mg. Confirm what you logged."
        case .logJournal:
            return "Log a daily journal behaviour for the user, e.g. alcohol, late meal, sauna, "
                + "meditation (yes/no via answered_yes) or a numeric one like drinks count (via value). "
                + "Use when the user reports something they did. Confirm what you logged."
        case .logLabMarker:
            return "Log a Lab Book health marker the user reports — a lab/blood value, body metric or "
                + "supplement dose (marker name + numeric value + unit). Confirm what you logged."
        case .sleepDetail:
            return "Get per-night sleep detail for recent nights: bed/wake times, efficiency, deep/REM/"
                + "light minutes, disturbances, plus the rolling 14-night sleep-debt balance. Use for "
                + "any question about sleep quality, stages or sleep debt."
        case .rangeReport:
            return "Get a range report over the last N days (7–365): per-metric averages, trends and "
                + "headline changes across recovery, sleep, HRV, resting HR, strain, workouts, stress. "
                + "Use for weekly/monthly reviews and 'how am I doing' questions."
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
        case .plotMetric:
            return [
                "type": "object",
                "properties": [
                    "metric": [
                        "type": "string",
                        "enum": ["charge", "effort", "hrv", "rhr", "sleep"],
                        "description": "Which metric to chart."
                    ],
                    "days": [
                        "type": "integer",
                        "description": "How many days back to plot (7–180). Defaults to 30."
                    ]
                ],
                "required": ["metric"]
            ]
        case .rememberFact:
            return [
                "type": "object",
                "properties": [
                    "fact": [
                        "type": "string",
                        "description": "One concise sentence stating the fact to remember."
                    ]
                ],
                "required": ["fact"]
            ]
        case .logCaffeine:
            return [
                "type": "object",
                "properties": [
                    "mg": [
                        "type": "number",
                        "description": "Estimated caffeine in milligrams. Omit if genuinely unknown."
                    ],
                    "minutes_ago": [
                        "type": "integer",
                        "description": "How many minutes ago it was consumed. Defaults to 0 (just now)."
                    ]
                ]
            ]
        case .logJournal:
            return [
                "type": "object",
                "properties": [
                    "behavior": [
                        "type": "string",
                        "description": "Short behaviour name, e.g. \"Alcohol\", \"Sauna\", \"Meditation\", \"Late meal\"."
                    ],
                    "answered_yes": [
                        "type": "boolean",
                        "description": "For yes/no behaviours: true = the user did it today."
                    ],
                    "value": [
                        "type": "number",
                        "description": "For numeric behaviours (e.g. drinks count) instead of answered_yes."
                    ],
                    "day": [
                        "type": "string",
                        "description": "The day it applies to, yyyy-MM-dd. Defaults to today; use yesterday when the user says so."
                    ]
                ],
                "required": ["behavior"]
            ]
        case .logLabMarker:
            return [
                "type": "object",
                "properties": [
                    "marker": [
                        "type": "string",
                        "description": "Marker name, e.g. \"Vitamin D\", \"Ferritin\", \"Weight\", \"Magnesium dose\"."
                    ],
                    "value": ["type": "number", "description": "The numeric value."],
                    "unit": ["type": "string", "description": "Unit, e.g. \"ng/mL\", \"kg\", \"mg\". Empty if none."],
                    "day": [
                        "type": "string",
                        "description": "The day it applies to, yyyy-MM-dd. Defaults to today."
                    ]
                ],
                "required": ["marker", "value"]
            ]
        case .sleepDetail:
            return [
                "type": "object",
                "properties": [
                    "nights": [
                        "type": "integer",
                        "description": "How many recent nights to include (1–14). Defaults to 7."
                    ]
                ]
            ]
        case .rangeReport:
            return [
                "type": "object",
                "properties": [
                    "days": [
                        "type": "integer",
                        "description": "Window length in days (7–365). Defaults to 7 (weekly review)."
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
        var tools: [CoachTool] = [
            .biometricSummary, .recentWorkouts, .stressIndex, .plotMetric,
            .sleepDetail, .rangeReport,
            .rememberFact, .logCaffeine, .logJournal, .logLabMarker
        ]
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
        case .plotMetric:
            let metric = (input["metric"] as? String) ?? ""
            let days = (input["days"] as? Int) ?? Int(input["days"] as? Double ?? 30)
            return handlePlotMetric(metric: metric, days: days)
        case .rememberFact:
            let fact = (input["fact"] as? String) ?? ""
            return CoachMemory.shared.add(fact)
                ? "Remembered: \(fact)"
                : "Nothing saved (empty or already remembered)."
        case .logCaffeine:
            let mg = (input["mg"] as? Double) ?? (input["mg"] as? Int).map(Double.init)
            let minsAgo = (input["minutes_ago"] as? Int) ?? Int(input["minutes_ago"] as? Double ?? 0)
            return logCaffeineTool(mg: mg, minutesAgo: minsAgo)
        case .logJournal:
            return await logJournalTool(
                behavior: (input["behavior"] as? String) ?? "",
                answeredYes: input["answered_yes"] as? Bool,
                value: (input["value"] as? Double) ?? (input["value"] as? Int).map(Double.init),
                day: input["day"] as? String
            )
        case .logLabMarker:
            let value = (input["value"] as? Double) ?? (input["value"] as? Int).map(Double.init)
            return await logLabMarkerTool(
                marker: (input["marker"] as? String) ?? "",
                value: value,
                unit: (input["unit"] as? String) ?? "",
                day: input["day"] as? String
            )
        case .sleepDetail:
            let nights = (input["nights"] as? Int) ?? Int(input["nights"] as? Double ?? 7)
            return await sleepDetailTool(nights: nights)
        case .rangeReport:
            let days = (input["days"] as? Int) ?? Int(input["days"] as? Double ?? 7)
            return await rangeReportTool(days: days)
        case .none:
            return "Unknown tool \"\(name)\"."
        }
    }
}
