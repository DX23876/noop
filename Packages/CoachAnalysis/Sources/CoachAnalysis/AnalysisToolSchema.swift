import Foundation

/// The `run_analysis` tool as offered to a model: its name, description and JSON Schema. One definition
/// serves the app and `Tools/CoachEval`, so the evaluation measures exactly what ships.
///
/// The schema stays inside the subset every provider accepts (Anthropic `input_schema`, OpenAI function
/// `parameters`, Gemini function declarations): plain `type` / `properties` / `required` / `enum` /
/// `items` / `description`, no `$ref`, no `oneOf`, no `additionalProperties`.
public enum AnalysisToolSchema {

    public static let name = "run_analysis"

    /// The tool description: what it is for and the few rules the model has to know to use it well. Kept
    /// short — it rides every request that offers the tool.
    public static let description = """
        Compute a statistic over the wearer's own local data. Use it whenever an answer depends on numbers \
        from their history: comparisons, trends, correlations, what happens after workouts or journal \
        behaviours, best and worst days. The app computes; you choose what. Never do the arithmetic yourself.

        Rules:
        • plan: one sentence in the wearer's language saying what you compute and why. It is shown to them.
        • Nightly metrics (sleep, overnight HRV, resting HR, respiration) are keyed by the day the wearer \
        woke up. For an anchor day D: night_before = the night ending on the morning of D; night_after = \
        the night starting on the evening of D. "Sleep after an evening workout" is night_after. Daily \
        metrics use same_day or next_day.
        • Prefer delta_from_baseline when comparing across months, so a slow drift in the baseline does not \
        masquerade as an effect.
        • Every test you run counts. Run the analysis that answers the question, not several hoping one \
        comes out significant; the result tells you how many ran and gives q-values corrected for all of them.
        • Report the result as returned: estimate, interval, n, and the verdict wording. Mention listed \
        confounders. "No reliable difference" never means "no difference".
        • If the call returns ANALYSIS NOT RUN, fix the named fields and call again.
        """

    /// The JSON Schema for the tool input. Pass the dataset to constrain metric, tag, event-kind and
    /// category names to what actually exists — invented names were the most common failure of
    /// wearable-data agents in published evaluations, and an enum removes them at the source.
    public static func inputSchema(for data: AnalysisDataset? = nil) -> [String: Any] {
        let seriesKeys = data.map { $0.series.keys.sorted() }
        let tagKeys = data.map { $0.tags.keys.sorted() }
        let eventKinds = data.map { $0.eventKinds.sorted() }
        let categories = data.map { set in Array(set.eventKinds.flatMap { set.categories(of: $0) }).sorted() }

        let condition = conditionSchema(seriesKeys: seriesKeys, tagKeys: tagKeys, eventKinds: eventKinds,
                                        categories: categories)
        let spec: [String: Any] = [
            "type": "object",
            "properties": [
                "operation": [
                    "type": "string",
                    "enum": AnalysisSpec.Operation.allCases.map(\.rawValue),
                    "description": "describe = level and spread; trend = change over time; compare_periods = two "
                        + "stretches of days; compare_groups = days meeting a condition vs others; correlate = two "
                        + "metrics together; event_response = the days after an event vs quiet days; rank_days = best "
                        + "or worst days (at most 5).",
                ],
                "window_days": [
                    "type": "integer",
                    "description": "Days of history, counted back from today (7–3650).",
                ],
                "metric": metricSchema(seriesKeys: seriesKeys, description: "The metric measured."),
                "metric2": metricSchema(seriesKeys: seriesKeys, description: "correlate: the second metric."),
                "lag_days": ["type": "integer", "description": "correlate: read metric2 this many days later (0–3)."],
                "groups": [
                    "type": "array",
                    "description": "compare_groups: one group (compared with every other day) or two.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string", "description": "Short name in the wearer's language."],
                            "when": condition,
                        ],
                        "required": ["label", "when"],
                    ],
                ],
                "periods": [
                    "type": "array",
                    "description": "compare_periods: exactly two, the more recent first.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string"],
                            "from_days_ago": ["type": "integer", "description": "Older end, inclusive (0 = today)."],
                            "to_days_ago": ["type": "integer", "description": "Newer end, inclusive."],
                        ],
                        "required": ["from_days_ago", "to_days_ago"],
                    ],
                ],
                "event": eventSchema(eventKinds: eventKinds, categories: categories,
                                     description: "event_response: the events whose aftermath is measured."),
                "response_days": ["type": "integer", "description": "event_response: days to follow (1–3)."],
                "filter": condition,
                "order": ["type": "string", "enum": ["highest", "lowest"], "description": "rank_days."],
                "limit": ["type": "integer", "description": "rank_days: how many days (1–5)."],
            ],
            "required": ["operation", "window_days", "metric"],
        ]
        return [
            "type": "object",
            "properties": [
                "plan": ["type": "string", "description": "One sentence: what you compute and why."],
                "spec": spec,
            ],
            "required": ["plan", "spec"],
        ]
    }

    private static func metricSchema(seriesKeys: [String]?, description: String) -> [String: Any] {
        var series: [String: Any] = ["type": "string", "description": "A metric key."]
        if let seriesKeys, !seriesKeys.isEmpty { series["enum"] = seriesKeys }
        return [
            "type": "object",
            "description": description,
            "properties": [
                "series": series,
                "align": [
                    "type": "string",
                    "enum": AnalysisSpec.Align.allCases.map(\.rawValue),
                    "description": "Required for nightly metrics in compare_groups, event_response and correlate.",
                ],
                "transform": [
                    "type": "string",
                    "enum": AnalysisSpec.Transform.allCases.map(\.rawValue),
                ],
            ],
            "required": ["series"],
        ]
    }

    private static func eventSchema(eventKinds: [String]?, categories: [String]?, description: String) -> [String: Any] {
        var kind: [String: Any] = ["type": "string"]
        if let eventKinds, !eventKinds.isEmpty { kind["enum"] = eventKinds }
        var category: [String: Any] = ["type": "string"]
        if let categories, !categories.isEmpty { category["enum"] = categories }
        return [
            "type": "object",
            "description": description,
            "properties": [
                "kind": kind,
                "categories": ["type": "array", "items": category],
                "start_hour_gte": ["type": "number", "description": "Local start hour, inclusive (0–24)."],
                "start_hour_lt": ["type": "number", "description": "Local start hour, exclusive (0–24)."],
                "min_duration_min": ["type": "number"],
                "min_intensity": ["type": "number"],
            ],
            "required": ["kind"],
        ]
    }

    private static func conditionSchema(seriesKeys: [String]?, tagKeys: [String]?, eventKinds: [String]?,
                                        categories: [String]?) -> [String: Any] {
        var tag: [String: Any] = ["type": "string", "description": "A yes/no tag such as a journal behaviour."]
        if let tagKeys, !tagKeys.isEmpty { tag["enum"] = tagKeys }
        var thresholdSeries: [String: Any] = ["type": "string"]
        if let seriesKeys, !seriesKeys.isEmpty { thresholdSeries["enum"] = seriesKeys }
        let event = eventSchema(eventKinds: eventKinds, categories: categories, description: "At least one such event that day.")
        return [
            "type": "object",
            "description": "Conditions on a day; all given must hold.",
            "properties": [
                "weekdays": ["type": "array", "items": ["type": "integer"], "description": "ISO: 1 = Monday … 7 = Sunday."],
                "tag": tag,
                "tag_value": ["type": "boolean", "description": "false selects days answered no. Default true."],
                "event": event,
                "no_event": eventSchema(eventKinds: eventKinds, categories: categories, description: "No such event that day."),
                "threshold": [
                    "type": "object",
                    "properties": [
                        "series": thresholdSeries,
                        "gte": ["type": "number"],
                        "lt": ["type": "number"],
                    ],
                    "required": ["series"],
                ],
            ],
        ]
    }
}
