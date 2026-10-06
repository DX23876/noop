import SwiftUI
import StrandDesign
import StrandAnalytics

/// One daily goal as a small chip: its symbol and "7,328 / 10,000". Once met it fills with the goal's
/// colour and shows a star (a tick for a goal done by hand), so the state reads without the colour too.
struct DailyGoalChip: View {
    let occurrence: GoalActionOccurrence

    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    private var isTick: Bool {
        switch occurrence.action.requirement {
        case .manual, .journal: return true
        case .workout(_, let minutes): return minutes == nil
        default: return false
        }
    }

    /// Done: a star for a number met, a filled tick for a box ticked. Open: the goal's own symbol, and an
    /// empty circle for a box still to tick (its usual symbol is a tick, which read as done).
    private var symbol: String {
        if occurrence.isCompleted { return isTick ? "checkmark.circle.fill" : "star.fill" }
        if case .manual = occurrence.action.requirement { return "circle" }
        return occurrence.ringSymbol
    }

    var body: some View {
        let tint = occurrence.identityColor(appleColors: appleColors)
        let done = occurrence.isCompleted
        Label {
            Text(occurrence.chipText)
                .font(done ? StrandFont.caption.weight(.semibold) : StrandFont.caption)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(done && !isTick ? StrandPalette.statusWarning : tint)
        }
        .labelStyle(DailyGoalChipLabelStyle())
        .padding(.horizontal, NoopMetrics.space2)
        .padding(.vertical, NoopMetrics.space1)
        .background(Capsule().fill(done ? tint.opacity(0.18) : StrandPalette.surfaceInset))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(occurrence.action.title). \(occurrence.detailLine)"))
    }
}

/// Icon and text closer together than the default label spacing, as a chip needs.
private struct DailyGoalChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            configuration.icon
            configuration.title
        }
    }
}
