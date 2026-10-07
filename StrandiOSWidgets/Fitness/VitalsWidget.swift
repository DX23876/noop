import WidgetKit
import SwiftUI
import StrandDesign

/// Last night's blood oxygen, respiratory rate and skin temperature against the wearer's usual range:
/// one line that says whether all are in range, then each value with its range.
struct NOOPVitalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPVitalsWidget", provider: FitnessProvider()) { entry in
            VitalsWidgetView(entry: entry).containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Vitals")
        .description("Last night's blood oxygen, breathing and skin temperature against your usual.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct VitalsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry

    private var fullColor: Bool { renderingMode == .fullColor }
    private var vitals: [FitnessWidgetSnapshot.Vital] { entry.snapshot?.vitals ?? [] }
    private var outside: Int { vitals.filter { $0.inRange == false }.count }
    private var judged: Bool { vitals.contains { $0.inRange != nil } }

    var body: some View {
        Group {
            if vitals.isEmpty {
                FitnessNoData(title: "Vitals", symbol: "waveform.path.ecg.rectangle", tint: StrandPalette.accent,
                              message: "Last night's vitals show here once it has been scored.")
            } else {
                switch family {
                case .accessoryInline: Text(shortSummary)
                case .accessoryRectangular: rectangular
                case .systemMedium: medium
                default: small
                }
            }
        }
        .widgetURL(URL(string: "noop://health"))
    }

    private var summary: String {
        guard judged else { return String(localized: "Learning your usual") }
        return outside == 0 ? String(localized: "All in your usual range")
                            : String(localized: "\(outside) outside your usual range")
    }

    /// The same verdict in the few words a small widget or the lock screen has room for.
    private var shortSummary: String {
        guard judged else { return String(localized: "Learning") }
        return outside == 0 ? String(localized: "All in range") : String(localized: "\(outside) out of range")
    }

    private var summaryTone: Color {
        guard fullColor, judged else { return StrandPalette.textSecondary }
        return outside == 0 ? StrandPalette.statusPositive : StrandPalette.statusWarningForeground
    }

    private var summarySymbol: String {
        guard judged else { return "hourglass" }
        return outside == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private func mark(_ vital: FitnessWidgetSnapshot.Vital) -> some View {
        Image(systemName: vital.inRange == false ? "exclamationmark.circle.fill" : "checkmark.circle")
            .foregroundStyle(vital.inRange == false && fullColor ? StrandPalette.statusWarningForeground
                                                                 : StrandPalette.textSecondary)
            .opacity(vital.inRange == nil ? 0 : 1)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: "Vitals", symbol: "waveform.path.ecg.rectangle", tint: StrandPalette.accent)
            Label(shortSummary, systemImage: summarySymbol).font(.caption.weight(.semibold))
                .foregroundStyle(summaryTone).lineLimit(1)
            Spacer(minLength: 0)
            ForEach(vitals) { vital in
                HStack(spacing: 4) {
                    Image(systemName: vital.symbol).frame(width: 16)
                    Text(vital.text).monospacedDigit()
                    Spacer(minLength: 4)
                    mark(vital)
                }
                .font(.caption2).lineLimit(1)
            }
            FitnessFootnote(entry: entry)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                FitnessWidgetHeader(title: "Vitals", symbol: "waveform.path.ecg.rectangle", tint: StrandPalette.accent)
                Spacer(minLength: 4)
                Label(summary, systemImage: summarySymbol).font(.caption.weight(.semibold))
                    .foregroundStyle(summaryTone).lineLimit(1)
            }
            Spacer(minLength: 0)
            ForEach(vitals) { vital in
                HStack(spacing: 8) {
                    // A fixed icon column, so the names line up whatever each symbol's width.
                    Image(systemName: vital.symbol).font(.caption2).frame(width: 16)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(vital.name).font(.caption2)
                        .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(vital.text).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                    if let usual = vital.usual {
                        WidgetRangeBar(value: vital.value, usual: usual,
                                       tint: vital.inRange == false ? StrandPalette.statusWarning : StrandPalette.accent,
                                       fullColor: fullColor)
                            .frame(width: 72, height: 12)
                    }
                }
            }
            Spacer(minLength: 0)
            FitnessFootnote(entry: entry)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(shortSummary, systemImage: summarySymbol).font(.caption.weight(.semibold)).lineLimit(1)
            Text(vitals.map(\.text).joined(separator: " · ")).font(.caption2).monospacedDigit().lineLimit(1)
        }
    }
}
