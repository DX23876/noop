import WidgetKit
import SwiftUI
import StrandDesign

/// Today's steps against the wearer's own step goal, and the last seven days against the same line.
struct NOOPStepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPStepsWidget", provider: FitnessProvider()) { entry in
            StepsWidgetView(entry: entry).containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Steps")
        .description("Today's steps against your step goal, and the past week.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry

    private var fullColor: Bool { renderingMode == .fullColor }
    private let tint = AppleInspiredColors.color(for: "coach.goal.weight")
    private var series: [Double?] { (entry.snapshot?.steps ?? []).map { $0.map(Double.init) } }
    private var goal: Double? { entry.snapshot?.stepsGoal.map(Double.init) }

    var body: some View {
        Group {
            if let latest = FitnessFormat.latest(series) {
                let today = latest.value
                switch family {
                case .accessoryInline: Text(String(localized: "\(FitnessFormat.whole(today)) steps"))
                case .accessoryCircular: circular(today)
                case .accessoryRectangular: rectangular(today)
                case .systemMedium: medium(today)
                default: small(today)
                }
            } else {
                FitnessNoData(title: "Steps", symbol: "figure.walk", tint: tint,
                              message: "Today's steps show here after the next sync.")
            }
        }
        .widgetURL(URL(string: "noop://metric/steps"))
    }

    private var goalLine: String? {
        goal.map { String(localized: "of \(FitnessFormat.whole($0)) goal") }
    }

    /// The day of the figure when it is not today's: no count for today yet is not zero steps.
    private var dayLine: String? {
        guard let index = series.lastIndex(where: { $0 != nil }), index < series.count - 1,
              let key = entry.snapshot?.days[safe: index] else { return nil }
        return FitnessFormat.day(key)
    }

    private func bars() -> some View {
        WidgetBarChart(values: FitnessWidgetSnapshot.tail(series, 7), goal: goal,
                       color: { _, v in (goal.map { v >= $0 } ?? false) ? tint : tint.opacity(0.5) },
                       fullColor: fullColor)
    }

    private func small(_ today: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: "Steps", symbol: "figure.walk", tint: tint)
            FitnessHero(value: FitnessFormat.whole(today))
            bars()
            FitnessFootnote(entry: entry, caption: dayLine ?? goalLine)
        }
    }

    private func medium(_ today: Double) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FitnessWidgetHeader(title: "Steps", symbol: "figure.walk", tint: tint)
                Spacer(minLength: 0)
                FitnessHero(value: FitnessFormat.whole(today))
                if let dayLine {
                    Text(dayLine).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                }
                if let goal {
                    Gauge(value: min(1, today / goal)) { EmptyView() }
                        .gaugeStyle(.linearCapacity).tint(tint)
                }
                FitnessFootnote(entry: entry, caption: goalLine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 days").font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                bars()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func circular(_ today: Double) -> some View {
        if let goal {
            Gauge(value: min(1, today / goal)) {
                Image(systemName: "figure.walk")
            } currentValueLabel: {
                Image(systemName: "figure.walk")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            VStack(spacing: 0) {
                Image(systemName: "figure.walk")
                Text(FitnessFormat.whole(today / 1000) + "k").font(.caption.weight(.semibold))
            }
        }
    }

    private func rectangular(_ today: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "\(FitnessFormat.whole(today)) steps"), systemImage: "figure.walk")
                .font(.caption.weight(.semibold)).lineLimit(1)
            if let goal {
                Gauge(value: min(1, today / goal)) { EmptyView() }
                    .gaugeStyle(.linearCapacity).tint(.primary)
                if let goalLine { Text(goalLine).font(.caption2).lineLimit(1) }
            }
        }
    }
}
