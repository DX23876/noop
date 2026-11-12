import Foundation
import StrandAnalytics

/// What a metric's detail page reads besides its chart, shared by iOS (`MetricDetailView`) and the Android core:
/// the window before the visible one, the statistics and change over it, and the catalog measures that moved with
/// the metric. Pure, so both platforms show the same numbers from the same series.
enum MetricDetailInsights {
    /// One measure that moved together with the page's metric over the visible window.
    struct Correlation: Equatable {
        let key: String
        let source: String
        let title: String
        let category: String
        let r: Double
        let n: Int
    }

    /// The measures each score is worked out from, by catalog key.
    static let scoreInputs: [String: Set<String>] = [
        "recovery": ["hrv", "rhr", "resp_rate", "skin_temp", "sleep_performance"],
        "stress": ["hrv", "rhr"],
    ]

    /// Whether one of the two keys is a score and the other one of its inputs, in either order.
    static func isScoreAndInput(_ a: String, _ b: String) -> Bool {
        (scoreInputs[a]?.contains(b) ?? false) || (scoreInputs[b]?.contains(a) ?? false)
    }

    /// The window immediately before the visible one, as many readings long, taken from the full [series]
    /// (ascending by day). Empty for the all-history view or when nothing precedes the window.
    static func previousWindow(series: [(day: String, value: Double)], windowed: [(day: String, value: Double)],
                               isAll: Bool) -> [(day: String, value: Double)] {
        guard !isAll, let firstDay = windowed.first?.day,
              let lo = series.firstIndex(where: { $0.day == firstDay }) else { return [] }
        let prevLo = max(0, lo - windowed.count)
        guard prevLo < lo else { return [] }
        return Array(series[prevLo..<lo])
    }

    /// The catalog measures whose daily values moved with [windowed] (|r| at least 0.30 over at least ten shared
    /// days), strongest first, at most six. A score beside its own inputs is left out: Charge moving with HRV says
    /// nothing the wearer did not know.
    static func correlations(metricKey: String, windowed: [(day: String, value: Double)],
                             others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])])
        -> [Correlation] {
        let myDays = Set(windowed.map(\.day))
        guard !myDays.isEmpty else { return [] }
        var rows: [Correlation] = []
        for entry in others {
            if isScoreAndInput(metricKey, entry.metric.key) { continue }
            let otherWindowed = entry.series.filter { myDays.contains($0.day) }
            let pairs = CorrelationEngine.alignByDay(windowed, otherWindowed)
            guard pairs.count >= 10, let c = CorrelationEngine.pearson(pairs), abs(c.r) >= 0.3 else { continue }
            rows.append(Correlation(key: entry.metric.key, source: entry.metric.source, title: entry.metric.title,
                                    category: entry.metric.category, r: c.r, n: c.n))
        }
        rows.sort { abs($0.r) > abs($1.r) }
        return Array(rows.prefix(6))
    }
}
