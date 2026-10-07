import WidgetKit
import SwiftUI
import StrandDesign

/// The HRV and resting-HR widgets: today's value, the wearer's usual range, and the last days as a line
/// over that range. One view for both, so they read exactly alike.
struct TrendMetricWidgetView: View {
    enum Metric {
        case hrv, restingHr
    }

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry
    let metric: Metric

    private var fullColor: Bool { renderingMode == .fullColor }
    private var title: LocalizedStringKey { metric == .hrv ? "HRV" : "Resting HR" }
    private var symbol: String { metric == .hrv ? "waveform.path.ecg" : "heart" }
    private var unit: String { metric == .hrv ? "ms" : "bpm" }
    private var tint: Color { metric == .hrv ? StrandPalette.energyResting : StrandPalette.liquidHeart }
    private var series: [Double?] { (metric == .hrv ? entry.snapshot?.hrv : entry.snapshot?.rhr) ?? [] }
    private var usual: FitnessWidgetSnapshot.Usual? { metric == .hrv ? entry.snapshot?.hrvUsual : entry.snapshot?.rhrUsual }
    private var link: URL? { URL(string: metric == .hrv ? "noop://metric/hrv" : "noop://metric/rhr") }

    var body: some View {
        Group {
            if let latest = FitnessFormat.latest(series) {
                switch family {
                case .accessoryInline:
                    Text("\(Text(title)) \(FitnessFormat.whole(latest.value)) \(unit)")
                case .accessoryRectangular: rectangular(latest.value)
                case .systemMedium: medium(latest)
                default: small(latest)
                }
            } else {
                FitnessNoData(title: title, symbol: symbol, tint: tint,
                              message: "Shows here after the first scored night.")
            }
        }
        .widgetURL(link)
    }

    private var usualLine: String? {
        usual.map { String(localized: "Usual \(FitnessFormat.whole($0.low))–\(FitnessFormat.whole($0.high)) \(unit)") }
    }

    /// Where today's value stands: inside the usual range, or above or below it.
    private func standing(_ value: Double) -> String? {
        guard let usual else { return nil }
        if usual.contains(value) { return String(localized: "In your usual range") }
        return value > usual.high ? String(localized: "Above your usual") : String(localized: "Below your usual")
    }

    private func small(_ latest: (value: Double, isLastDay: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: title, symbol: symbol, tint: tint)
            FitnessHero(value: FitnessFormat.whole(latest.value), unit: unit)
            WidgetLineChart(values: FitnessWidgetSnapshot.tail(series, 7), usual: usual, tint: tint,
                            fullColor: fullColor)
            FitnessFootnote(entry: entry, caption: usualLine)
        }
    }

    private func medium(_ latest: (value: Double, isLastDay: Bool)) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FitnessWidgetHeader(title: title, symbol: symbol, tint: tint)
                Spacer(minLength: 0)
                FitnessHero(value: FitnessFormat.whole(latest.value), unit: unit)
                if let standing = standing(latest.value) {
                    Text(standing).font(.caption2.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                }
                FitnessFootnote(entry: entry, caption: usualLine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 14 days").font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                WidgetLineChart(values: series, usual: usual, tint: tint, fullColor: fullColor)
            }
        }
    }

    private func rectangular(_ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                Spacer(minLength: 4)
                Text("\(FitnessFormat.whole(value)) \(unit)").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            WidgetLineChart(values: FitnessWidgetSnapshot.tail(series, 7), usual: usual, tint: tint, fullColor: false)
        }
    }
}

struct NOOPHrvWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPHrvWidget", provider: FitnessProvider()) { entry in
            TrendMetricWidgetView(entry: entry, metric: .hrv)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("HRV")
        .description("Today's heart rate variability against your usual range.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct NOOPRestingHrWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPRestingHrWidget", provider: FitnessProvider()) { entry in
            TrendMetricWidgetView(entry: entry, metric: .restingHr)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Resting HR")
        .description("Today's resting heart rate against your usual range.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
