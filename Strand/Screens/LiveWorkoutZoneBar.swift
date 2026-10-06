import SwiftUI
import StrandDesign

/// One heart-rate zone in the live rail. The current zone is taller, fully coloured and glows; the rest stay
/// faint. Colour is not the only signal: the current zone's label is bold and VoiceOver reads it as current.
struct LiveWorkoutZoneBar: View {
    let number: Int
    let isCurrent: Bool
    let isTarget: Bool
    let seconds: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { StrandPalette.hrZoneColor(number) }

    var body: some View {
        VStack(spacing: NoopMetrics.space1) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.accent)
                .opacity(isTarget ? 1 : 0)
                .accessibilityHidden(true)
            Capsule()
                .fill(isCurrent ? color : color.opacity(0.22))
                .frame(height: isCurrent ? 16 : 8)
                .shadow(color: isCurrent ? color.opacity(0.55) : .clear, radius: isCurrent ? 8 : 0)
            Text("Z\(number)")
                .font(StrandFont.captionNumber.weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            Text(ActiveWorkoutClock.clock(seconds))
                .font(StrandFont.captionNumber)
                .foregroundStyle(seconds > 0 ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: isCurrent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Zone \(number)"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        var parts = [ActiveWorkoutClock.clock(seconds)]
        if isCurrent { parts.insert(String(localized: "Current zone"), at: 0) }
        if isTarget { parts.append(String(localized: "Target zone")) }
        return parts.joined(separator: ", ")
    }
}
