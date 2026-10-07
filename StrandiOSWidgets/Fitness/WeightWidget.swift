import WidgetKit
import SwiftUI
import StrandDesign

/// The latest weigh-in with its date (the scale's number, never a smoothed trend), the change over the
/// last 30 days, and the weigh-ins of that window as a line.
struct NOOPWeightWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPWeightWidget", provider: FitnessProvider()) { entry in
            WeightWidgetView(entry: entry).containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Weight")
        .description("Your latest weigh-in and the last 30 days.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct WeightWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry

    private var fullColor: Bool { renderingMode == .fullColor }
    private let tint = AppleInspiredColors.color(for: "coach.goal.weight")

    var body: some View {
        Group {
            if let weight = entry.snapshot?.weight, let latest = weight.latest {
                switch family {
                case .accessoryInline: Text("\(FitnessFormat.oneDecimal(latest.value)) \(weight.unit)")
                case .accessoryRectangular: rectangular(weight, latest)
                case .systemMedium: medium(weight, latest)
                default: small(weight, latest)
                }
            } else {
                FitnessNoData(title: "Weight", symbol: "scalemass", tint: tint,
                              message: "Weigh-ins from NOOP or Apple Health show here.")
            }
        }
        .widgetURL(URL(string: "noop://weight"))
    }

    private func changeLine(_ weight: FitnessWidgetSnapshot.Weight) -> String? {
        guard let change = weight.change else { return nil }
        let sign = change > 0.05 ? "+" : (change < -0.05 ? "−" : "±")
        return String(localized: "\(sign)\(FitnessFormat.oneDecimal(abs(change))) \(weight.unit) in 30 days")
    }

    private func line(_ weight: FitnessWidgetSnapshot.Weight) -> some View {
        WidgetLineChart(values: weight.readings.map(\.value), tint: tint, fullColor: fullColor)
    }

    private func small(_ weight: FitnessWidgetSnapshot.Weight, _ latest: FitnessWidgetSnapshot.Weight.Reading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: "Weight", symbol: "scalemass", tint: tint)
            FitnessHero(value: FitnessFormat.oneDecimal(latest.value), unit: weight.unit)
            Text(FitnessFormat.day(latest.day)).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
            line(weight)
            FitnessFootnote(entry: entry, caption: changeLine(weight))
        }
    }

    private func medium(_ weight: FitnessWidgetSnapshot.Weight, _ latest: FitnessWidgetSnapshot.Weight.Reading) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FitnessWidgetHeader(title: "Weight", symbol: "scalemass", tint: tint)
                Spacer(minLength: 0)
                FitnessHero(value: FitnessFormat.oneDecimal(latest.value), unit: weight.unit)
                Text(String(localized: "Weighed \(FitnessFormat.day(latest.day))"))
                    .font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                FitnessFootnote(entry: entry, caption: changeLine(weight))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "\(weight.readings.count) weigh-ins, 30 days"))
                    .font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                line(weight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rectangular(_ weight: FitnessWidgetSnapshot.Weight, _ latest: FitnessWidgetSnapshot.Weight.Reading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(FitnessFormat.oneDecimal(latest.value)) \(weight.unit)", systemImage: "scalemass")
                .font(.headline).lineLimit(1)
            Text(FitnessFormat.day(latest.day)).font(.caption2).lineLimit(1)
            if let change = changeLine(weight) { Text(change).font(.caption2).lineLimit(1) }
        }
    }
}
