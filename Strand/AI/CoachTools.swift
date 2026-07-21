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
    /// Correct a fact already in memory (replace its text) — so the coach's memory self-heals.
    case updateFact = "update_fact"
    /// Forget a fact in memory that's no longer true.
    case forgetFact = "forget_fact"
    /// Search the user's PAST conversations for relevant history (cross-conversation recall).
    case searchPastConversations = "search_past_conversations"
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
    /// The on-device Readiness verdict — the SAME algorithm Today's synthesis card reads (level, ACWR,
    /// training monotony, contributing signals), plus a health/safety note when relevant.
    case readiness = "get_readiness"
    /// The ordered "why is my Charge what it is" breakdown — signed points per contributing term.
    case chargeDrivers = "get_charge_drivers"
    /// SUGGEST a session for a day. It lands as a proposal the USER must accept — never an active plan.
    case proposePlan = "propose_plan"
    /// What a session would cost, from the user's own history (+ what swapping it would change).
    case sessionOutlook = "get_session_outlook"
    /// "What if I train hard today and sleep 7h?" — project tomorrow's Charge.
    case simulateDay = "simulate_day"
    /// What the user agreed to vs what actually happened, with skip reasons.
    case planAdherence = "get_plan_adherence"
    /// READ back what the user has LOGGED — caffeine, journal behaviours, Lab Book, hydration, mood —
    /// closing the write-without-read gap (the coach can log a coffee but couldn't recall it).
    case myLogs = "get_my_logs"
    /// Time-in-zone minutes (Zone 1–5) over recent workouts, so a "did I hit Zone 2?" question — and
    /// `propose_plan`'s own Zone-2 prescriptions — can actually be checked against what was done.
    case zoneMinutes = "get_zone_minutes"

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
            return "Get the user's strongest personal patterns (their own n-of-1 correlations), a "
                + "personal dose-response read for alcohol/caffeine when they log doses, and a roll-up "
                + "of their logged Lab Book health numbers. Use to explain what helps or hurts them."
        case .plotMetric:
            return "Draw a chart of one metric over time, shown directly in the chat. Use it when a "
                + "trend is easier to see than to describe. metric is charge, effort, hrv, rhr or sleep, "
                + "or any other metric key this user actually has data for (e.g. stress, spo2, steps) — "
                + "an unavailable key returns a \"no data\" note instead of a chart."
        case .rememberFact:
            return "Save one durable fact about the user to your persistent memory (goals, injuries, "
                + "schedule, preferences, constraints). Call it PROACTIVELY whenever the user shares "
                + "something worth remembering across conversations. One concise sentence per fact. "
                + "Set importance=pinned only for facts that must frame EVERY reply (e.g. a serious "
                + "injury or hard constraint); most facts are normal. Pick the best category."
        case .updateFact:
            return "Correct a fact already in your memory when the user tells you it changed. Give the "
                + "old fact's gist (old) and the corrected sentence (new). Use this instead of remembering "
                + "a contradicting fact, so stale information doesn't pile up."
        case .forgetFact:
            return "Remove a fact from your memory that is no longer true (give its gist in fact). Use "
                + "when the user says something you remembered no longer applies."
        case .searchPastConversations:
            return "Look up the user's PAST conversations with you. Use it two ways, together or alone: "
                + "by KEYWORD (query) when the chat references something discussed before ('like we "
                + "talked about', 'my usual plan'), and by TIME (on_days_ago / since_days) when they ask "
                + "what was said on a particular day — 'what did I ask you yesterday?' takes "
                + "on_days_ago: 1 with NO query, because such a question contains no keywords to match. "
                + "Returns the user's own questions from each matching thread, dated."
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
                + "supplement dose (marker name + numeric value + unit). Call it when the user shares a "
                + "number from a blood test, checkup or scale, or a supplement dose ('my fasting glucose "
                + "was 92', 'weighed in at 82kg today', 'started 2000 IU vitamin D'). Confirm what you logged."
        case .sleepDetail:
            return "Get per-night sleep detail for recent nights: bed/wake times, efficiency, deep/REM/"
                + "light minutes, disturbances, plus the rolling 14-night sleep-debt balance. Use for "
                + "any question about sleep quality, stages or sleep debt."
        case .rangeReport:
            return "Get a range report over the last N days (7–365): per-metric averages, trends and "
                + "headline changes across recovery, sleep, HRV, resting HR, strain, workouts, stress. "
                + "Use for weekly/monthly reviews and 'how am I doing' questions."
        case .readiness:
            return "Get the user's on-device Readiness verdict — the SAME call the Today screen uses "
                + "(level: primed/balanced/strained/rundown/insufficient), acute:chronic workload ratio, "
                + "training monotony, and the contributing signals with plain-English detail. ALWAYS call "
                + "this before advising whether to push, maintain or rest — never derive that call "
                + "yourself from the raw charge number, so you never contradict what Today shows. May "
                + "include a HEALTH SIGNAL / SAFETY note; when present, do not suggest increasing "
                + "training load regardless of the readiness level."
        case .chargeDrivers:
            return "Get the ordered breakdown of WHY today's Charge is what it is — each contributing "
                + "term (HRV, resting HR, respiration, skin temperature) with its signed point "
                + "contribution, measured value, personal baseline, and a plain-English verdict. Use this "
                + "instead of guessing a reason when the user asks why their Charge/recovery is high or low."
        case .proposePlan:
            return "SUGGEST a training session for a day. This creates a PROPOSAL the user must accept, "
                + "decline or change in the app — it does NOT schedule anything, and you must never "
                + "describe it as settled. Use it when you recommend a specific session, AND when the "
                + "user tells you their own plan for a specific day (e.g. \"I'm training legs today\") — "
                + "either way it becomes a proposal they confirm, never assume it's already scheduled "
                + "just because they said it. Give a short rationale; they'll read it again next week."
        case .sessionOutlook:
            return "Find out what a session would cost this user, from THEIR OWN history: typical Charge "
                + "cost the next morning, bounce-back days, and a projection for tomorrow. Pass "
                + "swap_from to compare two activities side by side (e.g. they want CrossFit instead of "
                + "the easy ride). Use it before recommending or when they ask to change a session — "
                + "then let them decide."
        case .simulateDay:
            return "Project tomorrow-morning Charge for a hypothetical: a given effort today plus a "
                + "given number of hours' sleep tonight. Use for 'what if' questions ('can I go hard "
                + "today and still be fresh?'). Returns nothing when there's too little history to "
                + "project honestly."
        case .planAdherence:
            return "Get what the user agreed to versus what actually happened over recent days, "
                + "including WHY a session was skipped when they told us. Use it to open a check-in or "
                + "review. Never treat a skip as laziness — the reason is right there, and days whose "
                + "data is still calibrating carry no verdict at all."
        case .myLogs:
            return "Read back what the user has LOGGED, by kind: caffeine (intakes + what's still "
                + "active), journal (recent behaviours they recorded), lab (their Lab Book health "
                + "numbers), hydration (daily fluid vs goal) or mood (daily 1–5 check-ins). Call it when "
                + "a question turns on something they logged — 'is my coffee hurting my sleep?', 'how's "
                + "my hydration this week?' — so you answer from their real logs, not a guess. You can "
                + "log these; this is how you read them back."
        case .zoneMinutes:
            return "Get time-in-zone minutes (Zone 1–5, from the user's HR during recent workouts) over "
                + "the last N days. Use it to check whether they actually hit an intensity — especially "
                + "a Zone 2 session you prescribed — rather than assuming a plan was followed as written."
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
        case .personalPatterns:
            return [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "How many personal patterns to return (1–10). Defaults to 3."
                    ]
                ]
            ]
        case .plotMetric:
            return [
                "type": "object",
                "properties": [
                    "metric": [
                        "type": "string",
                        "description": "Which metric to chart: charge, effort, hrv, rhr, sleep, or any "
                            + "other metric key this user has data for."
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
                    ],
                    "category": [
                        "type": "string",
                        "enum": ["goal", "injury", "preference", "physiology", "schedule", "other"],
                        "description": "What the fact is about. Defaults to other."
                    ],
                    "importance": [
                        "type": "string",
                        "enum": ["pinned", "normal"],
                        "description": "pinned = must frame every reply (injuries, hard constraints); "
                            + "normal = surfaced when relevant. Defaults to normal."
                    ]
                ],
                "required": ["fact"]
            ]
        case .updateFact:
            return [
                "type": "object",
                "properties": [
                    "old": ["type": "string", "description": "The gist of the existing fact to correct."],
                    "new": ["type": "string", "description": "The corrected fact, one concise sentence."]
                ],
                "required": ["old", "new"]
            ]
        case .forgetFact:
            return [
                "type": "object",
                "properties": [
                    "fact": ["type": "string", "description": "The gist of the fact to forget."]
                ],
                "required": ["fact"]
            ]
        case .searchPastConversations:
            // NOTHING is required: a purely temporal question ("what did I ask you yesterday?") has no
            // keywords, and a purely topical one needs no date. Requiring `query` is what made the
            // temporal case unanswerable.
            return [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Keywords describing what to find. Omit for a purely "
                            + "time-based lookup."
                    ],
                    "on_days_ago": [
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 365,
                        "description": "Limit to ONE calendar day: 0 = today, 1 = yesterday, 2 = the "
                            + "day before. Use this for 'what did I ask you yesterday'."
                    ],
                    "since_days": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 365,
                        "description": "Limit to the last N days (a window, not a single day). Use for "
                            + "'earlier this week'."
                    ]
                ]
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
        case .proposePlan:
            return [
                "type": "object",
                "properties": [
                    "day": [
                        "type": "string",
                        "description": "The day it's for, yyyy-MM-dd. Defaults to today."
                    ],
                    "sport": [
                        "type": "string",
                        "description": "The activity, e.g. \"Zone 2 ride\", \"CrossFit\", \"Easy run\". "
                            + "Prefer wording that matches the user's own logged sports."
                    ],
                    "intent": [
                        "type": "string",
                        "enum": ["rest", "easy", "moderate", "hard", "mobility"],
                        "description": "How hard the session is meant to be."
                    ],
                    "target_effort": [
                        "type": "number",
                        "description": "Optional target Effort for the session (0–100)."
                    ],
                    "rationale": [
                        "type": "string",
                        "description": "One line on WHY this session, citing their numbers. They'll see "
                            + "it again when reviewing the plan."
                    ],
                    "time": [
                        "type": "string",
                        "description": "Optional time of day, HH:mm, if the user named one."
                    ]
                ],
                "required": ["sport", "intent"]
            ]
        case .sessionOutlook:
            return [
                "type": "object",
                "properties": [
                    "sport": [
                        "type": "string",
                        "description": "The activity to size up, e.g. \"CrossFit\"."
                    ],
                    "swap_from": [
                        "type": "string",
                        "description": "Optional: the activity it would REPLACE, to compare the two."
                    ],
                    "planned_effort": [
                        "type": "number",
                        "description": "Optional expected Effort (0–100) for the session."
                    ],
                    "planned_sleep_hours": [
                        "type": "number",
                        "description": "Optional sleep hours tonight; defaults to the user's typical."
                    ]
                ],
                "required": ["sport"]
            ]
        case .simulateDay:
            return [
                "type": "object",
                "properties": [
                    "effort": [
                        "type": "number",
                        "description": "Hypothetical Effort for today (0–100)."
                    ],
                    "sleep_hours": [
                        "type": "number",
                        "description": "Hypothetical sleep hours tonight."
                    ]
                ],
                "required": ["sleep_hours"]
            ]
        case .planAdherence:
            return [
                "type": "object",
                "properties": [
                    "days": [
                        "type": "integer",
                        "description": "How many days back to review (1–30). Defaults to 7."
                    ]
                ]
            ]
        case .myLogs:
            return [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["caffeine", "journal", "lab", "hydration", "mood"],
                        "description": "Which log to read back."
                    ],
                    "days": [
                        "type": "integer",
                        "description": "How many days back to include (1–90). Defaults to 14."
                    ]
                ],
                "required": ["kind"]
            ]
        case .zoneMinutes:
            return [
                "type": "object",
                "properties": [
                    "days": [
                        "type": "integer",
                        "description": "How many days back to total (1–90). Defaults to 7."
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

    /// OpenAI-compatible (OpenAI, OpenRouter) function descriptor — same underlying schema as
    /// `anthropicSpec`, wrapped in the `{type: "function", function: {...}}` shape those APIs expect.
    var openAIFunctionSpec: [String: Any] {
        ["type": "function", "function": ["name": rawValue, "description": description, "parameters": inputSchema]]
    }
}

// MARK: - Provider capability

/// What a tool-calling round produced: the reply text, and every tool actually called to ground it, in
/// call order (a name may repeat across rounds) — the "evidence chain" P6 surfaces per message so a user
/// can see what the answer is actually based on, not just read a claim.
struct CoachToolReply {
    let text: String
    let toolsUsed: [String]
}

/// A provider client that can run a tool-use loop. Providers opt in by conforming (see
/// `AnthropicClient`); the engine falls back to plain `send` for those that don't. Declared here
/// rather than in `AIProvider.swift` so tracking the upstream repo never conflicts on the protocol.
protocol ToolCallingClient {
    /// Run a multi-round tool-use conversation and return the final assistant text plus which tools
    /// grounded it. `runTool` executes a tool call by name and returns a compact text result to feed
    /// back to the model.
    func sendWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [CoachTool],
        runTool: (String, [String: Any]) async -> String,
        session: URLSession
    ) async throws -> CoachToolReply
}

// MARK: - Engine: tool availability + execution

extension AICoachEngine {

    /// The tools offered to the model, honouring consent: the patterns/Lab Book tool only appears when
    /// the second opt-in is on, mirroring `buildFullContext`'s gating.
    var coachTools: [CoachTool] {
        var tools: [CoachTool] = [
            .biometricSummary, .recentWorkouts, .stressIndex, .plotMetric,
            .sleepDetail, .rangeReport, .readiness, .chargeDrivers,
            .proposePlan, .sessionOutlook, .simulateDay, .planAdherence,
            .myLogs, .zoneMinutes,
            .rememberFact, .updateFact, .forgetFact, .searchPastConversations,
            .logCaffeine, .logJournal, .logLabMarker
        ]
        if includeOnDeviceSignals { tools.append(.personalPatterns) }
        return tools
    }

    /// True when the current turn should use the tool-use path: the user has granted data access, tools
    /// exist, and the chosen provider can run them. When false, the engine keeps the plain text-context path.
    ///
    /// OpenRouter fronts 300+ models from many vendors, and not every one of them can take tool
    /// definitions at all — the gate below additionally requires the SELECTED model to be confirmed
    /// tool-capable (`openRouterToolCapableModels`, populated by `refreshModels()` from the same
    /// `/models` response that lists the model). Before a first refresh that set is empty, so a fresh
    /// OpenRouter connection safely uses the context path rather than guessing a model can take tools
    /// and sending it a request it silently mishandles.
    var toolCallingActive: Bool {
        guard dataConsent, !coachTools.isEmpty, provider.client is ToolCallingClient else { return false }
        if provider == .openRouter { return openRouterToolCapableModels.contains(model) }
        return true
    }

    /// The context actually sent on the tool path — now ONLY the LIVING data: what's already on the
    /// table (pending proposals + commitments). The stable "you have tools, fetch before advising"
    /// prose moved to the CACHED system block (`AICoachEngine.toolModeClause`), where it's paid once
    /// rather than re-sent uncached in this user message every round. Without the plan block the model
    /// would be blind to its own pending proposals exactly when `propose_plan` is callable and re-propose
    /// them; `buildFullContext()` carries `planContextBlock()` on the non-tool path, so the tool path
    /// carries it here. Empty when nothing is pending — `wirePairs` then sends the question alone rather
    /// than wrapping a "Question:" scaffold around nothing.
    ///
    /// Two things ride alongside the plan block, both fixing the same reported failure ("what did I ask
    /// you yesterday?" → "I don't have that"):
    ///   • the CLOCK, because the tool path carried no date at all, so the model had nothing to resolve
    ///     a relative day against — `buildFullContext()` gets it via `buildContext()`, this path got
    ///     nothing;
    ///   • a THREAD INDEX (titles + dates), because the model otherwise has no reason to believe past
    ///     conversations exist and never calls `search_past_conversations`. Titles-only keeps it cheap;
    ///     the tool fetches the content on demand.
    /// Neither belongs in the system prompt: that block carries Anthropic's `cache_control` breakpoint,
    /// and a per-request clock would invalidate the prefix cache on every turn.
    var toolModeContext: String {
        [clockLine(), recentThreadsIndex(), planContextBlock() ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// An OPTIONAL integer argument, nil when the model omitted it. The inline
    /// `(x as? Int) ?? Int(x as? Double ?? default)` pattern used elsewhere in this dispatcher can't
    /// express "absent" — it has to invent a default — and here absent is meaningful: no `on_days_ago`
    /// means "don't filter by day at all", not "day 0". Providers also vary on whether a JSON integer
    /// arrives as `Int`, `Double` or a numeric `String`, so all three are accepted.
    static func intArg(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

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
            var block = buildContext()
            if let confidence = chargeConfidenceLine() { block += "\n\n" + confidence }
            return block
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
            let raw = (input["limit"] as? Int) ?? Int(input["limit"] as? Double ?? 3)
            let limit = max(1, min(raw, 10))
            let block = await onDeviceSignalsBlock(limit: limit)
            return block.isEmpty ? "No strong personal patterns have emerged yet." : block
        case .plotMetric:
            let metric = (input["metric"] as? String) ?? ""
            let days = (input["days"] as? Int) ?? Int(input["days"] as? Double ?? 30)
            return await handlePlotMetric(metric: metric, days: days)
        case .rememberFact:
            let fact = (input["fact"] as? String) ?? ""
            let category = (input["category"] as? String)
                .flatMap(CoachMemory.Category.init(rawValue:)) ?? .other
            let importance = (input["importance"] as? String)
                .flatMap(CoachMemory.Importance.init(rawValue:)) ?? .normal
            return CoachMemory.shared.add(fact, category: category, importance: importance)
                ? "Remembered: \(fact)"
                : "Nothing saved (the fact was empty)."
        case .updateFact:
            let old = (input["old"] as? String) ?? ""
            let new = (input["new"] as? String) ?? ""
            guard let match = CoachMemory.shared.firstMatch(old) else {
                return "No matching fact found to update; use remember_fact to add it instead."
            }
            return CoachMemory.shared.update(match.id, text: new)
                ? "Updated to: \(new)"
                : "Nothing updated (the new text was empty)."
        case .forgetFact:
            let fact = (input["fact"] as? String) ?? ""
            guard let match = CoachMemory.shared.firstMatch(fact) else {
                return "No matching fact found to forget."
            }
            CoachMemory.shared.remove(match.id)
            return "Forgotten: \(match.text)"
        case .searchPastConversations:
            return searchPastConversations(query: (input["query"] as? String) ?? "",
                                           sinceDays: Self.intArg(input["since_days"]),
                                           onDaysAgo: Self.intArg(input["on_days_ago"]))
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
        case .readiness:
            return readinessBlock()
        case .chargeDrivers:
            var block = chargeDriversBlock()
            if let confidence = chargeConfidenceLine() { block += "\n\n" + confidence }
            return block
        case .proposePlan:
            return proposePlanTool(
                day: input["day"] as? String,
                sport: (input["sport"] as? String) ?? "",
                intent: (input["intent"] as? String) ?? "",
                targetEffort: (input["target_effort"] as? Double)
                    ?? (input["target_effort"] as? Int).map(Double.init),
                rationale: (input["rationale"] as? String) ?? "",
                time: input["time"] as? String)
        case .sessionOutlook:
            return await sessionOutlookTool(
                sport: (input["sport"] as? String) ?? "",
                swapFrom: input["swap_from"] as? String,
                plannedEffort: (input["planned_effort"] as? Double)
                    ?? (input["planned_effort"] as? Int).map(Double.init),
                plannedSleepHours: (input["planned_sleep_hours"] as? Double)
                    ?? (input["planned_sleep_hours"] as? Int).map(Double.init))
        case .simulateDay:
            let sleep = (input["sleep_hours"] as? Double)
                ?? (input["sleep_hours"] as? Int).map(Double.init)
            return await simulateDayTool(
                effort: (input["effort"] as? Double) ?? (input["effort"] as? Int).map(Double.init),
                sleepHours: sleep)
        case .planAdherence:
            let days = (input["days"] as? Int) ?? Int(input["days"] as? Double ?? 7)
            return await planAdherenceBlock(days: max(1, min(days, 30)))
        case .myLogs:
            let raw = (input["days"] as? Int) ?? Int(input["days"] as? Double ?? 14)
            return await myLogsTool(kind: (input["kind"] as? String) ?? "", days: max(1, min(raw, 90)))
        case .zoneMinutes:
            let raw = (input["days"] as? Int) ?? Int(input["days"] as? Double ?? 7)
            return await zoneMinutesTool(days: max(1, min(raw, 90)))
        case .none:
            return "Unknown tool \"\(name)\"."
        }
    }
}
