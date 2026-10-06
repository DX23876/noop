import SwiftUI
import StrandDesign

/// One live metric, Workout-app style: a large number with its unit in small caps beside it, a symbol on
/// the trailing edge and an optional one-line caption. Shared by every row on the live screen so they all
/// have the same rhythm.
struct LiveWorkoutMetricRow: View {
    let value: String
    let unit: String
    var caption: String? = nil
    var symbol: String? = nil
    var tint: Color = StrandPalette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(value)
                    .font(StrandFont.number(44)).monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(StrandFont.headline)
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let symbol {
                    Image(systemName: symbol)
                        .font(StrandFont.headline)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
            }
            if let caption {
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    /// Splits a formatted reading like "1.2 km" or "5:52 /km" into number and unit at the last space.
    static func split(_ formatted: String) -> (value: String, unit: String) {
        guard let space = formatted.lastIndex(of: " ") else { return (formatted, "") }
        return (String(formatted[..<space]), String(formatted[formatted.index(after: space)...]))
    }
}
