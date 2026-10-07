import WidgetKit
import SwiftUI
import StrandDesign

/// The Charge and Effort week widgets: today's score large, the last seven days as bars in their own
/// zone colours, the weekday letters under them on the medium size.
struct WeekBarsWidgetView: View {
    enum Metric {
        case charge, effort
    }

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry
    let metric: Metric

    private var fullColor: Bool { renderingMode == .fullColor }
    private var title: LocalizedStringKey { metric == .charge ? "Charge" : "Effort" }
    private var symbol: String { metric == .charge ? "bolt.heart" : "flame" }
    /// The colours the app's own rings use: Charge by its band, Effort one fixed accent (as the NOOP
    /// widget and Today draw them), so a day reads the same here and there.
    private var tint: Color {
        metric == .charge ? StrandPalette.chargeRingColor(series.last.flatMap { $0 } ?? 70) : StrandPalette.effortColor
    }
    private var series: [Double?] { (metric == .charge ? entry.snapshot?.charge : entry.snapshot?.effort) ?? [] }
    private var week: [Double?] { FitnessWidgetSnapshot.tail(series, 7) }
    private var link: URL? { URL(string: metric == .charge ? "noop://metric/recovery" : "noop://trainingLoad") }

    /// The figure as the app shows it: Charge in percent, Effort in the wearer's own scale.
    private func text(at index: Int) -> String? {
        guard series.indices.contains(index), let value = series[index] else { return nil }
        if metric == .charge { return "\(Int(value.rounded())) %" }
        if let stored = entry.snapshot?.effortTexts[safe: index], let text = stored { return text }
        return FitnessFormat.whole(value)
    }

    private func color(_ value: Double) -> Color {
        metric == .charge ? StrandPalette.chargeRingColor(value) : StrandPalette.effortColor
    }

    var body: some View {
        Group {
            if let index = series.lastIndex(where: { $0 != nil }), let figure = text(at: index) {
                switch family {
                case .accessoryInline: Text("\(Text(title)) \(figure)")
                case .accessoryCircular: circular(series[index] ?? 0, figure: figure)
                case .accessoryRectangular: rectangular(figure)
                case .systemMedium: medium(figure, isToday: index == series.count - 1)
                default: small(figure, isToday: index == series.count - 1)
                }
            } else {
                FitnessNoData(title: title, symbol: symbol, tint: tint,
                              message: "Shows here once a day has been scored.")
            }
        }
        .widgetURL(link)
    }

    private var average: String? {
        let xs = week.compactMap { $0 }
        guard !xs.isEmpty else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        if metric == .charge { return String(localized: "7-day average \(Int(mean.rounded())) %") }
        return String(localized: "7-day average \(FitnessFormat.whole(mean))")
    }

    private func bars(height: CGFloat?) -> some View {
        WidgetBarChart(values: week, maximum: 100, color: { _, v in color(v) }, fullColor: fullColor)
            .frame(height: height)
    }

    private func small(_ figure: String, isToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: title, symbol: symbol, tint: tint)
            FitnessHero(value: figure)
            bars(height: nil)
            FitnessFootnote(entry: entry, caption: isToday ? nil : String(localized: "Today not scored yet"))
        }
    }

    private func medium(_ figure: String, isToday: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FitnessWidgetHeader(title: title, symbol: symbol, tint: tint)
                Spacer(minLength: 0)
                FitnessHero(value: figure)
                if let average {
                    Text(average).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                }
                FitnessFootnote(entry: entry, caption: isToday ? nil : String(localized: "Today not scored yet"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                bars(height: nil)
                HStack(spacing: 4) {
                    ForEach(Array(FitnessWidgetSnapshot.tail(entry.snapshot?.dayLetters ?? [], 7).enumerated()),
                            id: \.offset) { _, letter in
                        Text(letter).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func circular(_ value: Double, figure: String) -> some View {
        Gauge(value: min(1, max(0, value / 100))) {
            Image(systemName: symbol)
        } currentValueLabel: {
            Text(metric == .charge ? "\(Int(value.rounded()))" : figure).monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private func rectangular(_ figure: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                Spacer(minLength: 4)
                Text(figure).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            WidgetBarChart(values: week, maximum: 100, color: { _, _ in .primary }, fullColor: false)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct NOOPChargeWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPChargeWeekWidget", provider: FitnessProvider()) { entry in
            WeekBarsWidgetView(entry: entry, metric: .charge)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Charge week")
        .description("Today's Charge and the last seven days at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct NOOPEffortWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPEffortWeekWidget", provider: FitnessProvider()) { entry in
            WeekBarsWidgetView(entry: entry, metric: .effort)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Effort week")
        .description("Today's Effort and the load of the last seven days.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
