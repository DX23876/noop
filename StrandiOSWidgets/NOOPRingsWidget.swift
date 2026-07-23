import WidgetKit
import SwiftUI
import StrandDesign

/// The home-screen "three rings" widget (redesign briefing §9/§4): Charge, Effort and Rest, drawn the same
/// way the Today hero does — a trimmed circle per score, tinted by its Signature family colour, with the
/// number centred. Small shows Charge alone (the one score that matters most at a glance); medium shows all
/// three side by side, matching the Today hero row. Shares `NOOPProvider`'s timeline (`WidgetSnapshot`,
/// republished by `WidgetPublish.swift`), so this is a second presentation of the SAME data as `NOOPWidget`,
/// not a second data path.
private struct RingGauge: View {
    let value: Int?
    let maxValue: Double
    let tint: Color
    let label: String
    var decimals: Int = 0

    private var fraction: Double {
        guard let value else { return 0 }
        return max(0, min(1, Double(value) / maxValue))
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(StrandPalette.hairline, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map(String.init) ?? "–")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 52, height: 52)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

struct NOOPRingsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 0) {
                RingGauge(value: snap.recovery, maxValue: 100, tint: StrandPalette.chargeColor, label: "Charge")
                    .frame(maxWidth: .infinity)
                RingGauge(value: snap.effort, maxValue: 100, tint: StrandPalette.effortColor, label: "Effort")
                    .frame(maxWidth: .infinity)
                RingGauge(value: snap.rest, maxValue: 100, tint: StrandPalette.restColor, label: "Rest")
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
        default:
            // .systemSmall: Charge alone — the one score that matters most at a glance (matches the
            // lock-screen accessory's headline choice in NOOPWidget).
            RingGauge(value: snap.recovery, maxValue: 100, tint: StrandPalette.chargeColor, label: "Charge")
                .padding(12)
        }
    }
}

struct NOOPRingsWidget: Widget {
    let kind = "NOOPRingsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPRingsWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                NOOPRingsWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("NOOP Rings")
        .description("Charge, Effort and Rest as three rings, just like Today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
