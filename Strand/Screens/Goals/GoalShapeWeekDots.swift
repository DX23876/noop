import SwiftUI
import StrandDesign
import StrandAnalytics

/// The last finished weeks, oldest first. A kept week is a filled dot in the goal's colour, an almost
/// kept one half-filled, a missed one an empty ring (grey, never red), one without data dashed. Filled
/// against empty tells the weeks apart without relying on colour.
struct GoalShapeWeekDots: View {
    let weeks: [PeriodOutcome]
    let tint: Color

    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 10

    var body: some View {
        HStack(spacing: NoopMetrics.space1) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, outcome in
                dot(outcome).frame(width: diameter, height: diameter)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: GoalShapeGlyph.height)
    }

    @ViewBuilder
    private func dot(_ outcome: PeriodOutcome) -> some View {
        switch outcome {
        case .achieved: Circle().fill(tint)
        case .almost: Circle().fill(tint.opacity(0.4)).overlay { Circle().strokeBorder(tint, lineWidth: 1.5) }
        case .missed: Circle().strokeBorder(StrandPalette.textTertiary, lineWidth: 1.5)
        case .protected:
            Circle().fill(StrandPalette.surfaceInset)
                .overlay { Circle().strokeBorder(StrandPalette.textTertiary, lineWidth: 1) }
        case .noData:
            Circle().strokeBorder(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }
}
