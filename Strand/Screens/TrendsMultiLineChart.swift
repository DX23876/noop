#if !os(watchOS)
import SwiftUI
import Charts
import StrandDesign
import WhoopStore

/// Three fixed-colour lines over the same 14-day window — Charge (green), Effort (orange — `DailyMetric.strain`
/// is already this app's own 0…100 load score, the same axis Charge and Rest use, so no rescale is needed),
/// Rest (violet). No existing chart covers this:
/// `TrendChart` is single-series with a VALUE-ramp gradient line, and `CompareView`'s overlay chart
/// normalizes arbitrary metrics 0…1 with an auto-assigned categorical palette — neither is "three fixed
/// domain colours, one shared axis", which is what the reference draws.
///
/// Deliberately no Charts legend or axis labels: the caller (`TrendsDashboardView`) already draws its
/// own colour-dot legend with the current values to the chart's left, matching the reference.
struct TrendsMultiLineChart: View {
    let days: [DailyMetric]
    /// Rest is a separate scored series ("sleep_performance"), not a `DailyMetric` column — see
    /// `TrendsDashboardView.load()`.
    let restByDay: [String: Double]
    let domain: ClosedRange<Date>

    /// `series` is load-bearing, not decorative: three independent `ForEach`-built `LineMark` sequences
    /// sharing the same x-domain (all 14 dates), each styled with only a literal `.foregroundStyle(color)`,
    /// gave Swift Charts no way to tell them apart as separate paths — it interpolated all three into one
    /// merged path and painted the whole thing in whichever series happened to dominate (every line
    /// rendered green; only the trailing `PointMark`s, styled independently, kept their real colour).
    /// `.foregroundStyle(by: .value(...))` + `.chartForegroundStyleScale(...)` is the documented Charts
    /// pattern for multiple distinct-coloured series and is what actually keeps the three paths separate.
    private struct Point: Identifiable {
        let date: Date
        let value: Double
        let series: String
        let segment: String
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    private static let chargeSeries = "Charge"
    private static let effortSeries = "Effort"
    private static let restSeries = "Rest"

    private var chargePoints: [Point] { points(series: Self.chargeSeries) { $0.recovery } }

    private var effortPoints: [Point] { points(series: Self.effortSeries) { $0.strain } }

    private var restPoints: [Point] { points(series: Self.restSeries) { restByDay[$0.day] } }

    /// Split a series whenever a calendar day is absent. Connecting across a gap suggests a measured
    /// trend that does not exist, which is especially misleading on a health dashboard.
    private func points(series: String, value: (DailyMetric) -> Double?) -> [Point] {
        var segment = 0
        var previous: Date?
        return days.compactMap { day in
            guard let date = Self.date(day.day) else { return nil }
            defer { previous = date }
            if let previous, Calendar.current.dateComponents([.day], from: previous, to: date).day != 1 {
                segment += 1
            }
            guard let metricValue = value(day) else { segment += 1; return nil }
            return Point(date: date, value: metricValue, series: series, segment: "\(series)-\(segment)")
        }
    }

    var body: some View {
        Chart {
            line(chargePoints)
            line(effortPoints)
            line(restPoints)
        }
        .chartForegroundStyleScale([
            Self.chargeSeries: StrandPalette.chargeColor,
            Self.effortSeries: StrandPalette.effortColor,
            Self.restSeries: StrandPalette.restColor,
        ])
        .chartYScale(domain: 0...100)
        .chartXScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }

    @ChartContentBuilder
    private func line(_ points: [Point]) -> some ChartContent {
        ForEach(points) { p in
            LineMark(x: .value("Date", p.date), y: .value("Value", p.value),
                     series: .value("Segment", p.segment))
                .foregroundStyle(by: .value("Series", p.series))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                .symbolSize(8)
                .foregroundStyle(by: .value("Series", p.series))
        }
        if let last = points.last {
            PointMark(x: .value("Date", last.date), y: .value("Value", last.value))
                .symbolSize(28)
                .foregroundStyle(by: .value("Series", last.series))
        }
    }

    private static func date(_ key: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: key)
    }
}
#endif
