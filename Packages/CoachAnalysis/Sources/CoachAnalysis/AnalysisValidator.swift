import Foundation

/// Checks a spec against the dataset before anything runs. Every issue names the field and says what would
/// be valid — PHIA's largest error classes were invented columns and wrong windows, and an error the model
/// can read and correct turns a failed attempt into a second, right one.
public enum AnalysisValidator {

    public static let windowRange = 7...3_650
    public static let lagRange = 0...3
    public static let responseRange = 1...3
    public static let rankLimitRange = 1...5

    public static func validate(_ spec: AnalysisSpec, against data: AnalysisDataset) -> [AnalysisIssue] {
        var issues: [AnalysisIssue] = []
        func fail(_ field: String, _ message: String) { issues.append(.init(field: field, message: message)) }

        if !windowRange.contains(spec.windowDays) {
            fail("spec.window_days", "must be between \(windowRange.lowerBound) and \(windowRange.upperBound)")
        }

        let needsAlignedMetric: Bool
        switch spec.operation {
        case .describe, .trend, .comparePeriods, .rankDays:
            needsAlignedMetric = false
        case .compareGroups, .eventResponse, .correlate:
            needsAlignedMetric = true
        }

        if let metric = spec.metric {
            checkMetric(metric, field: "spec.metric", requireAlign: needsAlignedMetric, data: data, fail: fail)
        } else {
            fail("spec.metric", "is required for \(spec.operation.rawValue)")
        }

        switch spec.operation {
        case .describe, .trend:
            break
        case .rankDays:
            if spec.order == nil { fail("spec.order", "is required for rank_days: highest or lowest") }
            if let limit = spec.limit, !rankLimitRange.contains(limit) {
                fail("spec.limit", "must be between 1 and 5")
            }
        case .comparePeriods:
            guard let periods = spec.periods, periods.count == 2 else {
                fail("spec.periods", "must hold exactly two periods")
                break
            }
            for (i, period) in periods.enumerated() {
                let field = "spec.periods[\(i)]"
                if period.toDaysAgo < 0 || period.fromDaysAgo < period.toDaysAgo {
                    fail(field, "needs from_days_ago ≥ to_days_ago ≥ 0 (0 is today; from is the older end)")
                }
                if period.fromDaysAgo >= spec.windowDays {
                    fail(field + ".from_days_ago", "must lie inside window_days (\(spec.windowDays))")
                }
            }
            let a = periods[0], b = periods[1]
            if max(a.toDaysAgo, b.toDaysAgo) <= min(a.fromDaysAgo, b.fromDaysAgo) {
                fail("spec.periods", "must not overlap")
            }
        case .compareGroups:
            guard let groups = spec.groups, (1...2).contains(groups.count) else {
                fail("spec.groups", "must hold one group (compared with all other days) or two")
                break
            }
            for (i, group) in groups.enumerated() {
                let label = group.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty || label.count > 40 {
                    fail("spec.groups[\(i)].label", "must be 1–40 characters")
                }
                checkCondition(group.when, field: "spec.groups[\(i)].when", data: data, fail: fail)
            }
        case .correlate:
            if let second = spec.metric2 {
                checkMetric(second, field: "spec.metric2", requireAlign: true, data: data, fail: fail)
            } else {
                fail("spec.metric2", "is required for correlate")
            }
            if let lag = spec.lagDays, !lagRange.contains(lag) { fail("spec.lag_days", "must be 0–3") }
        case .eventResponse:
            if let event = spec.event {
                checkEvent(event, field: "spec.event", data: data, fail: fail)
            } else {
                fail("spec.event", "is required for event_response")
            }
            if let days = spec.responseDays, !responseRange.contains(days) {
                fail("spec.response_days", "must be 1–3")
            }
        }

        if let filter = spec.filter { checkCondition(filter, field: "spec.filter", data: data, fail: fail) }
        return issues
    }

    // MARK: - Parts

    private static func checkMetric(_ metric: AnalysisSpec.MetricRef, field: String, requireAlign: Bool,
                                    data: AnalysisDataset, fail: (String, String) -> Void) {
        guard let series = data.series[metric.series] else {
            fail(field + ".series", unknown("metric", metric.series, among: Array(data.series.keys)))
            return
        }
        guard let align = metric.align else {
            if requireAlign && series.kind == .nightly {
                fail(field + ".align", "is required for the nightly series \(metric.series): night_before "
                     + "(the night ending that morning) or night_after (the night starting that evening)")
            }
            return
        }
        switch (series.kind, align) {
        case (.daily, .sameDay), (.daily, .nextDay), (.nightly, .nightBefore), (.nightly, .nightAfter):
            break
        case (.daily, _):
            fail(field + ".align", "\(metric.series) is a daily series: use same_day or next_day")
        case (.nightly, _):
            fail(field + ".align", "\(metric.series) is a nightly series: use night_before or night_after")
        }
    }

    private static func checkCondition(_ condition: AnalysisSpec.Condition, field: String,
                                       data: AnalysisDataset, fail: (String, String) -> Void) {
        if let weekdays = condition.weekdays, weekdays.isEmpty || weekdays.contains(where: { !(1...7).contains($0) }) {
            fail(field + ".weekdays", "must list ISO weekdays 1 (Monday) … 7 (Sunday)")
        }
        if let tag = condition.tag, data.tags[tag] == nil {
            fail(field + ".tag", unknown("tag", tag, among: Array(data.tags.keys)))
        }
        if condition.tagValue != nil && condition.tag == nil {
            fail(field + ".tag_value", "needs tag")
        }
        if let event = condition.event { checkEvent(event, field: field + ".event", data: data, fail: fail) }
        if let event = condition.noEvent { checkEvent(event, field: field + ".no_event", data: data, fail: fail) }
        if let threshold = condition.threshold {
            if data.series[threshold.series] == nil {
                fail(field + ".threshold.series", unknown("metric", threshold.series, among: Array(data.series.keys)))
            }
            if threshold.gte == nil && threshold.lt == nil {
                fail(field + ".threshold", "needs gte, lt or both")
            }
        }
        let empty = condition.weekdays == nil && condition.tag == nil && condition.event == nil
            && condition.noEvent == nil && condition.threshold == nil
        if empty { fail(field, "must set at least one of weekdays, tag, event, no_event, threshold") }
    }

    private static func checkEvent(_ event: AnalysisSpec.EventFilter, field: String, data: AnalysisDataset,
                                   fail: (String, String) -> Void) {
        guard data.eventKinds.contains(event.kind) else {
            fail(field + ".kind", unknown("event kind", event.kind, among: Array(data.eventKinds)))
            return
        }
        let known = data.categories(of: event.kind)
        for (i, category) in (event.categories ?? []).enumerated() where !known.contains(category) {
            fail(field + ".categories[\(i)]", unknown("category", category, among: Array(known)))
        }
        for (name, hour) in [("start_hour_gte", event.startHourGte), ("start_hour_lt", event.startHourLt)] {
            if let hour, !(0...24).contains(hour) { fail(field + "." + name, "must be an hour 0–24") }
        }
    }

    // MARK: - Suggestions

    /// "unknown metric `sleep_eff`; closest: sleep_efficiency, sleep_deep_min" — the nearest keys by edit
    /// distance, so a near miss is fixed on the next attempt instead of guessed at again.
    static func unknown(_ noun: String, _ value: String, among keys: [String]) -> String {
        guard !keys.isEmpty else { return "unknown \(noun) `\(value)`; none are available" }
        let ranked = keys.sorted {
            let l = editDistance(value.lowercased(), $0.lowercased())
            let r = editDistance(value.lowercased(), $1.lowercased())
            return l != r ? l < r : $0 < $1
        }
        return "unknown \(noun) `\(value)`; closest: " + ranked.prefix(3).joined(separator: ", ")
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
