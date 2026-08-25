import WidgetKit
import SwiftUI
import StrandDesign

/// Dedicated expenditure widget. A total has no meaningful 0...goal ring unless the user configures a
/// calorie target, so this widget deliberately uses numbers and an active/basal composition instead.
struct NOOPEnergyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var energy: WidgetEnergySnapshot? {
        guard let energy = entry.snapshot.energy,
              energy.day == WidgetSnapshot.localDayKey(entry.date) else { return nil }
        return energy
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            default: small
            }
        }
        .widgetURL(URL(string: "noop://energy"))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var inline: some View {
        if let total = energy?.totalKcal {
            Text("🔥 \(number(total)) kcal today")
        } else {
            Text("No energy data today")
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Energy", systemImage: "flame.fill")
                .font(.caption2.weight(.semibold))
            Text(energy?.totalKcal.map { "\(number($0)) kcal" } ?? "—")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 8) {
                if let projected = energy?.projectedKcal {
                    Text("~\(number(projected)) projected")
                } else if let active = energy?.activeKcal {
                    Text("\(number(active)) active")
                } else {
                    Text("No energy data today")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            Text(energy?.totalKcal.map(number) ?? "—")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
            Text(energy == nil ? "No energy data today" : "kcal total so far")
                .font(.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            if let active = energy?.activeKcal {
                Label("\(number(active)) active", systemImage: "figure.run")
                    .font(.caption2)
                    .foregroundStyle(StrandPalette.effortColor)
            }
            quality
            calibration
        }
        .padding(12)
    }

    private var medium: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer(minLength: 0)
                Text(energy?.totalKcal.map { "\(number($0)) kcal" } ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text("total burned so far")
                    .font(.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                quality
                calibration
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                stat("Projected today", energy?.projectedKcal, approximate: true)
                composition
                if let asOf = energy?.asOf {
                    HStack(spacing: 3) {
                        Text("Updated")
                        Text(asOf, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    @ViewBuilder private var calibration: some View {
        if let factor = energy?.calibrationFactorPermille {
            Text(verbatim: calibrationText(factor: factor))
                .font(.caption2)
                .foregroundStyle(StrandPalette.textSecondary)
        } else if let uncertainty = energy?.uncertaintyPercent {
            Text(verbatim: uncertaintyText(uncertainty))
                .font(.caption2)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func calibrationText(factor: Int) -> String {
        "WHOOP · ×" + (Double(factor) / 1_000)
            .formatted(.number.precision(.fractionLength(3)))
    }

    private func uncertaintyText(_ percent: Int) -> String {
        "WHOOP · ±\(percent) %"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .foregroundStyle(StrandPalette.metricAmber)
            Text("ENERGY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var quality: some View {
        if let energy {
            HStack(spacing: 5) {
                Circle().fill(qualityColor(energy.confidence)).frame(width: 6, height: 6)
                Text(qualityLabel(energy.confidence))
            }
            .font(.caption2)
            .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 4) {
            stat("Active", energy?.activeKcal)
            stat("Basal", energy?.basalKcal,
                 approximate: energy?.source != "appleSplit")
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: Int?, approximate: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 4)
            Text(value.map { (approximate ? "~" : "") + number($0) + " kcal" } ?? "—")
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
        .font(.caption2)
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func qualityLabel(_ confidence: String) -> LocalizedStringKey {
        switch confidence {
        case "solid": return "Measured"
        case "building": return "Partly estimated"
        default: return "Estimated"
        }
    }

    private func qualityColor(_ confidence: String) -> Color {
        switch confidence {
        case "solid": return StrandPalette.statusPositive
        case "building": return StrandPalette.metricAmber
        default: return StrandPalette.textTertiary
        }
    }
}
struct NOOPEnergyWidget: Widget {
    let kind = "NOOPEnergyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPEnergyWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                NOOPEnergyWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("NOOP Energy")
        .description("Total, active and basal calories for today, with an honest projection.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}
