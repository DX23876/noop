import Foundation

/// A compact, local-only view of a metric over a long period. It deliberately emits aggregates and
/// bounded time buckets rather than a raw daily series, so a remote coach provider can reason about a
/// multi-year change without receiving the user's full underlying history.
struct CoachMetricHistory {
    struct Point: Equatable {
        let day: String
        let value: Double
    }

    /// Candidate series are compared locally before any aggregate is returned to a provider. Keeping one
    /// source avoids silently blending unlike measurements (for example scale weight and a wearable's
    /// estimate), while preferring the widest coverage makes a deep-history question genuinely deep.
    struct SourceSeries: Equatable {
        let source: String
        let points: [Point]
    }

    /// A compact provenance line for a locally resolved timeline.  The model receives coverage only,
    /// never a list of individual source readings, but can still say where a long-range conclusion
    /// came from (for example Apple Health before a strap was paired, then WHOOP afterwards).
    static func sourceSummary(from points: [ResolvedMetricPoint],
                              label: (String) -> String) -> String {
        let grouped = Dictionary(grouping: points, by: \.source)
        let orderedSources = points.reduce(into: [String]()) { result, point in
            if !result.contains(point.source) { result.append(point.source) }
        }
        return orderedSources.compactMap { source in
            guard let rows = grouped[source],
                  let first = rows.map(\.day).min(), let last = rows.map(\.day).max() else { return nil }
            let span = first == last ? first : "\(first) → \(last)"
            return "\(label(source)) (\(span); \(rows.count) days)"
        }.joined(separator: "; ")
    }

    static func bestAvailableSeries(from candidates: [SourceSeries]) -> SourceSeries? {
        let usable = candidates.filter { $0.points.count >= 2 }
        return usable.sorted { left, right in
            let leftSpan = coverageDays(left.points)
            let rightSpan = coverageDays(right.points)
            if leftSpan != rightSpan { return leftSpan > rightSpan }
            if left.points.count != right.points.count { return left.points.count > right.points.count }
            let leftLatest = left.points.map(\.day).max() ?? ""
            let rightLatest = right.points.map(\.day).max() ?? ""
            if leftLatest != rightLatest { return leftLatest > rightLatest }
            return left.source < right.source
        }.first
    }

    private static func coverageDays(_ points: [Point]) -> Int {
        guard let first = points.map(\.day).min(), let last = points.map(\.day).max(),
              let from = localDay(first), let to = localDay(last) else { return 0 }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: from, to: to).day ?? 0
    }

    private static func localDay(_ day: String) -> Date? {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(
            calendar: Calendar(identifier: .gregorian), year: pieces[0], month: pieces[1], day: pieces[2]
        ))
    }

    /// Builds a stable, small evidence block for the coach. `points` may contain a sparse body metric
    /// such as weight or a daily wearable metric. Duplicate days resolve to the last value, matching the
    /// store's normal last-write-wins semantics.
    static func report(metric: String, source: String, unit: String?, points: [Point]) -> String {
        var byDay: [String: Double] = [:]
        for point in points where point.value.isFinite { byDay[point.day] = point.value }
        let rows = byDay.keys.sorted().compactMap { day in byDay[day].map { Point(day: day, value: $0) } }
        guard rows.count >= 3 else {
            return "Not enough local \(metric) history to analyse a privacy-preserving trend yet."
        }

        let values = rows.map(\.value)
        let mean = values.reduce(0, +) / Double(values.count)
        let midpoint = max(1, rows.count / 2)
        let firstMean = rows.prefix(midpoint).map(\.value).reduce(0, +) / Double(midpoint)
        let secondRows = rows.dropFirst(midpoint)
        let secondMean = secondRows.map(\.value).reduce(0, +) / Double(secondRows.count)
        let tolerance = max(abs(mean) * 0.01, 0.05)
        let direction: String
        if secondMean - firstMean > tolerance { direction = "rising" }
        else if firstMean - secondMean > tolerance { direction = "falling" }
        else { direction = "broadly stable" }

        let suffix = unit.map { " \($0)" } ?? ""
        let format: (Double) -> String = { value in
            let decimals = abs(value) >= 100 ? 0 : (abs(value) >= 10 ? 1 : 2)
            return String(format: "%.*f", decimals, value)
        }
        var lines = [
            "LOCAL METRIC HISTORY — \(metric) (\(source))",
            "Coverage: \(rows.first!.day) → \(rows.last!.day); \(rows.count) recorded days.",
            "Summary: mean \(format(mean))\(suffix) across the selected local history.",
            "Trend: \(direction)."
        ]

        let buckets = bucketed(rows)
        if buckets.isEmpty {
            lines.append("Aggregated timeline withheld: this history is too sparse to form non-raw time groups.")
        } else {
            lines.append("Aggregated timeline (not raw readings):")
            lines.append(contentsOf: buckets.map { bucket in
                "  • \(bucket.label): mean \(format(bucket.mean))\(suffix) (n=\(bucket.count))"
            })
        }
        return lines.joined(separator: "\n")
    }

    private struct Bucket {
        let label: String
        let mean: Double
        let count: Int
    }

    /// Keep the result bounded: 12 month buckets for up to a year, then calendar quarters. This is a
    /// privacy boundary as well as a context-cost boundary; it is never a covert raw-data export.
    private static func bucketed(_ rows: [Point]) -> [Bucket] {
        guard let first = rows.first, let last = rows.last else { return [] }
        let years = max(1, Int(last.day.prefix(4)) ?? 1) - (Int(first.day.prefix(4)) ?? 1) + 1
        let useQuarter = years > 1
        var values: [String: [Double]] = [:]
        for row in rows {
            let month = Int(row.day.dropFirst(5).prefix(2)) ?? 1
            let label: String
            if useQuarter {
                label = "\(row.day.prefix(4)) Q\(((month - 1) / 3) + 1)"
            } else {
                label = String(row.day.prefix(7))
            }
            values[label, default: []].append(row.value)
        }
        // More than 24 buckets adds context without helping a coach answer a question. Adjacent
        // quarters are intentionally coalesced when an unusually long history would exceed that cap.
        let keys = values.keys.sorted()
        let stride = max(1, Int(ceil(Double(keys.count) / 24.0)))
        let cappedGroups = keys.enumerated().reduce(into: [[String]]()) { grouped, item in
                if item.offset % stride == 0 { grouped.append([]) }
                grouped[grouped.count - 1].append(item.element)
            }

        // A one- or two-point time group would merely relabel a raw reading. Coalesce adjacent calendar
        // groups until each released value represents at least three local observations. If the whole
        // history is sparser than that, the summary can still state its direction, but no timeline leaves
        // the device.
        var privateGroups: [[String]] = []
        var pending: [String] = []
        for group in cappedGroups {
            pending.append(contentsOf: group)
            let count = pending.reduce(0) { $0 + (values[$1]?.count ?? 0) }
            if count >= 3 {
                privateGroups.append(pending)
                pending = []
            }
        }
        if !pending.isEmpty {
            if privateGroups.isEmpty { return [] }
            privateGroups[privateGroups.count - 1].append(contentsOf: pending)
        }
        return privateGroups.compactMap { group in
            let all = group.flatMap { values[$0] ?? [] }
            guard let firstLabel = group.first else { return nil }
            let label = group.count == 1 ? firstLabel : "\(firstLabel)–\(group.last!)"
            return makeBucket(label: label, values: all)
        }
    }

    private static func makeBucket(label: String, values: [Double]) -> Bucket? {
        guard values.count >= 3 else { return nil }
        return Bucket(label: label, mean: values.reduce(0, +) / Double(values.count), count: values.count)
    }
}
