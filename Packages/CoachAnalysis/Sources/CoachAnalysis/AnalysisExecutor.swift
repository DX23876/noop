import Foundation

/// Runs a validated spec over a dataset. Returns aggregates only: counts, means, medians, intervals and
/// correlation coefficients — never a list of daily readings, except the at most five days `rank_days`
/// is explicitly asked for.
public struct AnalysisExecutor {

    /// The fewest values a group, a period or a described metric needs before the executor reports it.
    public static let minimumGroupSize = 5
    public static let minimumDescribe = 3
    /// Trends and correlations need more points: a slope or ρ over a handful of days is mostly noise.
    public static let minimumSeriesPoints = 10
    /// A confounder is reported when the compared days differ on it by at least this much.
    static let confounderEffectSize = 0.5
    static let confounderShareGap = 0.25

    let data: AnalysisDataset
    private let today: Int
    private let seriesByOrdinal: [String: [Int: Double]]
    private let eventsByDay: [Int: [AnalysisEvent]]

    public init(data: AnalysisDataset) {
        self.data = data
        self.today = DayKey.ordinal(data.today) ?? 0
        var bySeries: [String: [Int: Double]] = [:]
        for (key, series) in data.series {
            var map: [Int: Double] = [:]
            for (day, value) in series.values {
                if let ordinal = DayKey.ordinal(day) { map[ordinal] = value }
            }
            bySeries[key] = map
        }
        self.seriesByOrdinal = bySeries
        var events: [Int: [AnalysisEvent]] = [:]
        for event in data.events {
            if let ordinal = DayKey.ordinal(event.day) { events[ordinal, default: []].append(event) }
        }
        self.eventsByDay = events
    }

    /// Runs `spec`, which must already have passed `AnalysisValidator`.
    public func run(_ spec: AnalysisSpec, plan: String) -> AnalysisResult {
        let first = today - spec.windowDays + 1
        let candidates = (first...today).filter { day in spec.filter.map { matches($0, day) } ?? true }
        let metric = spec.metric ?? .init(series: "")
        let series = data.series[metric.series]
        var result = AnalysisResult(
            operation: spec.operation, plan: plan,
            windowFrom: DayKey.string(first), windowTo: DayKey.string(today),
            metricLabel: label(metric), unit: series?.unit,
            facts: [], tests: [], confounders: [], notes: [])
        let seed = AnalysisStatistics.fnv1a(canonical(spec))

        switch spec.operation {
        case .describe: describe(metric, candidates, &result)
        case .trend: trend(metric, candidates, seed, &result)
        case .comparePeriods: comparePeriods(spec, metric, candidates, seed, &result)
        case .compareGroups: compareGroups(spec, metric, candidates, seed, &result)
        case .correlate: correlate(spec, metric, candidates, seed, &result)
        case .eventResponse: eventResponse(spec, metric, candidates, seed, &result)
        case .rankDays: rankDays(spec, metric, candidates, &result)
        }
        if spec.filter != nil {
            result.notes.append("\(candidates.count) of \(spec.windowDays) days in the window passed the filter.")
        }
        return result
    }

    // MARK: - Operations

    private func describe(_ metric: AnalysisSpec.MetricRef, _ days: [Int], _ result: inout AnalysisResult) {
        let values = days.compactMap { value(metric, at: $0) }
        guard values.count >= Self.minimumDescribe else {
            result.notes.append("Only \(values.count) day(s) with a value — too few to describe (need \(Self.minimumDescribe)).")
            return
        }
        let unit = result.unit
        result.facts.append("n = \(values.count) days with a value (of \(days.count)).")
        result.facts.append("Mean " + AnalysisFormat.withUnit(AnalysisFormat.number(AnalysisStatistics.mean(values)!), unit)
                            + ", median " + AnalysisFormat.withUnit(AnalysisFormat.number(AnalysisStatistics.median(values)!), unit) + ".")
        if let sd = AnalysisStatistics.standardDeviation(values),
           let q1 = AnalysisStatistics.quantile(values, 0.25), let q3 = AnalysisStatistics.quantile(values, 0.75) {
            result.facts.append("Spread: SD " + AnalysisFormat.number(sd) + ", middle half of days "
                                + AnalysisFormat.number(q1) + "–" + AnalysisFormat.withUnit(AnalysisFormat.number(q3), unit) + ".")
        }
    }

    private func trend(_ metric: AnalysisSpec.MetricRef, _ days: [Int], _ seed: UInt64,
                       _ result: inout AnalysisResult) {
        let points = days.compactMap { day in value(metric, at: day).map { (Double(day), $0) } }
        guard points.count >= Self.minimumSeriesPoints,
              let slope = AnalysisStatistics.olsSlope(points.map(\.0), points.map(\.1)) else {
            result.notes.append("Only \(points.count) day(s) with a value — too few for a trend (need \(Self.minimumSeriesPoints)).")
            return
        }
        let per30 = slope * 30
        let boot = AnalysisStatistics.blockBootstrap(count: points.count, seed: seed, estimate: per30) { idx in
            AnalysisStatistics.olsSlope(idx.map { points[$0].0 }, idx.map { points[$0].1 }).map { $0 * 30 }
        }
        result.facts.append("n = \(points.count) days with a value.")
        guard let boot else {
            result.notes.append("The trend could not be resampled; the data is too uniform.")
            return
        }
        result.tests.append(.init(label: "change per 30 days", estimate: per30, lower: boot.lower,
                                  upper: boot.upper, p: boot.p, n: points.count, effectSize: nil, inMetricUnit: true))
    }

    private func comparePeriods(_ spec: AnalysisSpec, _ metric: AnalysisSpec.MetricRef, _ days: [Int],
                                _ seed: UInt64, _ result: inout AnalysisResult) {
        guard let periods = spec.periods, periods.count == 2 else { return }
        let allowed = Set(days)
        var entries: [(day: Int, group: Int, value: Double)] = []
        var labels: [String] = []
        for (g, period) in periods.enumerated() {
            let from = today - period.fromDaysAgo, to = today - period.toDaysAgo
            let name = period.label?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "\(DayKey.string(from)) → \(DayKey.string(to))"
            labels.append(name)
            for day in from...to where allowed.contains(day) {
                if let v = value(metric, at: day) { entries.append((day, g, v)) }
            }
        }
        compareTwo(entries: entries, labels: labels, seed: seed, anchorsForConfounders: nil, metric: metric,
                   result: &result)
    }

    private func compareGroups(_ spec: AnalysisSpec, _ metric: AnalysisSpec.MetricRef, _ days: [Int],
                               _ seed: UInt64, _ result: inout AnalysisResult) {
        guard let groups = spec.groups, !groups.isEmpty else { return }
        let labels = groups.count == 2 ? groups.map(\.label) : [groups[0].label, "all other days"]
        var entries: [(day: Int, group: Int, value: Double)] = []
        var anchors: [[Int]] = [[], []]
        var overlap = 0
        for day in days {
            let inA = matches(groups[0].when, day)
            let inB = groups.count == 2 ? matches(groups[1].when, day) : !inA
            if inA && inB { overlap += 1; continue }
            guard inA || inB else { continue }
            let g = inA ? 0 : 1
            anchors[g].append(day)
            if let v = value(metric, at: day) { entries.append((day, g, v)) }
        }
        if overlap > 0 {
            result.notes.append("\(overlap) day(s) met both conditions and were left out of both groups.")
        }
        compareTwo(entries: entries, labels: labels, seed: seed, anchorsForConfounders: anchors, metric: metric,
                   result: &result)
    }

    private func eventResponse(_ spec: AnalysisSpec, _ metric: AnalysisSpec.MetricRef, _ days: [Int],
                               _ seed: UInt64, _ result: inout AnalysisResult) {
        guard let filter = spec.event else { return }
        let span = spec.responseDays ?? 1
        let eventDays = days.filter { hasEvent(filter, on: $0) }
        let quietDays = days.filter { day in !(0...span).contains { hasEvent(filter, on: day - $0) } }
        let baseline = quietDays.compactMap { day in value(metric, at: day).map { (day, $0) } }
        result.facts.append("\(eventDays.count) event day(s); \(baseline.count) quiet day(s) with a value as the baseline "
                            + "(no such event that day or the \(span) before).")
        for step in 1...span {
            var entries: [(day: Int, group: Int, value: Double)] = baseline.map { ($0.0, 1, $0.1) }
            for day in eventDays {
                if let v = value(metric, at: day + step - 1) { entries.append((day, 0, v)) }
            }
            entries.sort { $0.day < $1.day }
            let dayLabel = step == 1 ? "after the event" : "\(step) days after the event"
            compareTwo(entries: entries, labels: [dayLabel, "baseline"],
                       seed: seed &+ UInt64(step), anchorsForConfounders: step == 1 ? [eventDays, quietDays] : nil,
                       metric: metric, result: &result)
        }
    }

    private func correlate(_ spec: AnalysisSpec, _ metric: AnalysisSpec.MetricRef, _ days: [Int],
                           _ seed: UInt64, _ result: inout AnalysisResult) {
        guard let second = spec.metric2 else { return }
        let lag = spec.lagDays ?? 0
        let pairs = days.compactMap { day -> (Double, Double)? in
            guard let x = value(metric, at: day), let y = value(second, at: day + lag) else { return nil }
            return (x, y)
        }
        let lagText = lag == 0 ? "on the same anchor day" : "read \(lag) day(s) later"
        result.facts.append("n = \(pairs.count) paired days: \(label(metric)) against \(label(second)), \(lagText).")
        guard pairs.count >= Self.minimumSeriesPoints,
              let rho = AnalysisStatistics.spearman(pairs.map(\.0), pairs.map(\.1)) else {
            result.notes.append("Too few paired days, or one metric never varied (need \(Self.minimumSeriesPoints)).")
            return
        }
        if let r = AnalysisStatistics.pearson(pairs.map(\.0), pairs.map(\.1)) {
            result.facts.append("Pearson r = " + String(format: "%.2f", r) + " (for comparison; ρ is the headline).")
        }
        guard let boot = AnalysisStatistics.blockBootstrap(count: pairs.count, seed: seed, estimate: rho, statistic: { idx in
            AnalysisStatistics.spearman(idx.map { pairs[$0].0 }, idx.map { pairs[$0].1 })
        }) else {
            result.notes.append("The correlation could not be resampled.")
            return
        }
        result.tests.append(.init(label: "Spearman ρ", estimate: rho, lower: boot.lower, upper: boot.upper,
                                  p: boot.p, n: pairs.count, effectSize: nil, inMetricUnit: false))
        result.notes.append("A correlation is not a cause: both can follow a third factor, such as training load or illness.")
    }

    private func rankDays(_ spec: AnalysisSpec, _ metric: AnalysisSpec.MetricRef, _ days: [Int],
                          _ result: inout AnalysisResult) {
        let values = days.compactMap { day in value(metric, at: day).map { (day, $0) } }
        guard !values.isEmpty else {
            result.notes.append("No day in the window has a value.")
            return
        }
        let highest = spec.order != .lowest
        let limit = min(max(spec.limit ?? 3, 1), 5)
        let ranked = values.sorted { highest ? ($0.1, $1.0) > ($1.1, $0.0) : ($0.1, $0.0) < ($1.1, $1.0) }
        result.facts.append("\(highest ? "Highest" : "Lowest") \(min(limit, ranked.count)) of \(values.count) days:")
        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        for (day, v) in ranked.prefix(limit) {
            result.facts.append("  • \(DayKey.string(day)) (\(weekdays[DayKey.isoWeekday(day) - 1])): "
                                + AnalysisFormat.withUnit(AnalysisFormat.number(v), result.unit))
        }
    }

    // MARK: - Two-group comparison

    private func compareTwo(entries: [(day: Int, group: Int, value: Double)], labels: [String], seed: UInt64,
                            anchorsForConfounders: [[Int]]?, metric: AnalysisSpec.MetricRef,
                            result: inout AnalysisResult) {
        let a = entries.filter { $0.group == 0 }.map(\.value)
        let b = entries.filter { $0.group == 1 }.map(\.value)
        let unit = result.unit
        for (name, values) in zip(labels, [a, b]) {
            let mean = AnalysisStatistics.mean(values).map { AnalysisFormat.withUnit(AnalysisFormat.number($0), unit) } ?? "—"
            result.facts.append("\(name): n = \(values.count), mean \(mean)")
        }
        guard a.count >= Self.minimumGroupSize, b.count >= Self.minimumGroupSize,
              let ma = AnalysisStatistics.mean(a), let mb = AnalysisStatistics.mean(b) else {
            result.notes.append("Too few days to compare \(labels[0]) with \(labels[1]) (need \(Self.minimumGroupSize) in each).")
            return
        }
        let ordered = entries.sorted { $0.day < $1.day }
        let boot = AnalysisStatistics.blockBootstrap(count: ordered.count, seed: seed, estimate: ma - mb) { idx in
            var sa = 0.0, na = 0, sb = 0.0, nb = 0
            for i in idx {
                if ordered[i].group == 0 { sa += ordered[i].value; na += 1 } else { sb += ordered[i].value; nb += 1 }
            }
            guard na >= 2, nb >= 2 else { return nil }
            return sa / Double(na) - sb / Double(nb)
        }
        guard let boot else {
            result.notes.append("The comparison could not be resampled.")
            return
        }
        result.tests.append(.init(label: "\(labels[0]) − \(labels[1])", estimate: ma - mb, lower: boot.lower,
                                  upper: boot.upper, p: boot.p, n: a.count + b.count,
                                  effectSize: AnalysisStatistics.hedgesG(a, b), inMetricUnit: true))
        if let anchors = anchorsForConfounders {
            result.confounders += confounders(groupA: anchors[0], groupB: anchors[1], labels: labels,
                                              excluding: metric.series)
        }
    }

    /// Other measured differences between the two sets of anchor days. Reported, never adjusted for: the
    /// point is to tell the wearer what else changed, not to pretend a regression settled it.
    private func confounders(groupA: [Int], groupB: [Int], labels: [String], excluding measured: String) -> [String] {
        var found: [String] = []
        for key in data.confounderKeys where key != measured {
            if let series = data.series[key] {
                let ref = AnalysisSpec.MetricRef(series: key, align: series.kind == .nightly ? .nightBefore : .sameDay)
                let a = groupA.compactMap { value(ref, at: $0) }
                let b = groupB.compactMap { value(ref, at: $0) }
                guard a.count >= Self.minimumGroupSize, b.count >= Self.minimumGroupSize,
                      let g = AnalysisStatistics.hedgesG(a, b), abs(g) >= Self.confounderEffectSize else { continue }
                let when = series.kind == .nightly ? " the night before" : ""
                found.append("\(labels[0]) days also had \(g > 0 ? "higher" : "lower") \(key)\(when) "
                             + "(standardised difference \(String(format: "%.1f", g))).")
            } else if let tag = data.tags[key] {
                let a = groupA.filter { tag.answered.contains(DayKey.string($0)) }
                let b = groupB.filter { tag.answered.contains(DayKey.string($0)) }
                guard a.count >= Self.minimumGroupSize, b.count >= Self.minimumGroupSize else { continue }
                let share = { (days: [Int]) in Double(days.filter { tag.yes.contains(DayKey.string($0)) }.count) / Double(days.count) }
                let gap = share(a) - share(b)
                guard abs(gap) >= Self.confounderShareGap else { continue }
                found.append("\(key) was answered yes on \(Int((share(a) * 100).rounded())) % of \(labels[0]) days "
                             + "vs \(Int((share(b) * 100).rounded())) % of \(labels[1]) days.")
            }
        }
        return found
    }

    // MARK: - Values and conditions

    /// The value a metric contributes for anchor day `day`, after alignment and transform.
    func value(_ metric: AnalysisSpec.MetricRef, at day: Int) -> Double? {
        guard let map = seriesByOrdinal[metric.series] else { return nil }
        let offset: Int
        switch metric.align {
        case .nextDay?, .nightAfter?: offset = 1
        case .sameDay?, .nightBefore?, nil: offset = 0
        }
        let target = day + offset
        guard target <= today else { return nil }
        switch metric.transform ?? .none {
        case .none:
            return map[target]
        case .rollingMean7:
            let window = (target - 6...target).compactMap { map[$0] }
            return window.count >= 4 ? AnalysisStatistics.mean(window) : nil
        case .deltaFromBaseline:
            guard let v = map[target] else { return nil }
            let prior = (target - 28...target - 1).compactMap { map[$0] }
            guard prior.count >= 14, let baseline = AnalysisStatistics.median(prior) else { return nil }
            return v - baseline
        }
    }

    func matches(_ condition: AnalysisSpec.Condition, _ day: Int) -> Bool {
        if let weekdays = condition.weekdays, !weekdays.contains(DayKey.isoWeekday(day)) { return false }
        if let key = condition.tag {
            guard let tag = data.tags[key] else { return false }
            let dayKey = DayKey.string(day)
            guard tag.answered.contains(dayKey) else { return false }
            if tag.yes.contains(dayKey) != (condition.tagValue ?? true) { return false }
        }
        if let event = condition.event, !hasEvent(event, on: day) { return false }
        if let event = condition.noEvent, hasEvent(event, on: day) { return false }
        if let threshold = condition.threshold {
            guard let v = seriesByOrdinal[threshold.series]?[day] else { return false }
            if let gte = threshold.gte, v < gte { return false }
            if let lt = threshold.lt, v >= lt { return false }
        }
        return true
    }

    func hasEvent(_ filter: AnalysisSpec.EventFilter, on day: Int) -> Bool {
        (eventsByDay[day] ?? []).contains { event in
            guard event.kind == filter.kind else { return false }
            if let categories = filter.categories, !categories.contains(event.category ?? "") { return false }
            if let gte = filter.startHourGte, event.startHour < gte { return false }
            if let lt = filter.startHourLt, event.startHour >= lt { return false }
            if let min = filter.minDurationMin, (event.durationMin ?? 0) < min { return false }
            if let min = filter.minIntensity, (event.intensity ?? -.infinity) < min { return false }
            return true
        }
    }

    // MARK: - Helpers

    private func label(_ metric: AnalysisSpec.MetricRef) -> String {
        var text = metric.series
        if let align = metric.align { text += " (\(align.rawValue.replacingOccurrences(of: "_", with: " ")))" }
        switch metric.transform ?? .none {
        case .none: break
        case .rollingMean7: text += ", 7-day mean"
        case .deltaFromBaseline: text += ", vs own 28-day baseline"
        }
        return text
    }

    private func canonical(_ spec: AnalysisSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(spec)).flatMap { String(data: $0, encoding: .utf8) } ?? spec.operation.rawValue
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
