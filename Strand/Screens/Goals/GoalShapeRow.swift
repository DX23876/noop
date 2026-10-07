import SwiftUI
import StrandDesign

/// One goal on Today's card: its name and state on top, where it stands in its own terms under it
/// ("642 km of 1,000 km", "207.3 kg, measured 5 Oct, target 190 kg"), and the goal drawn in its shape.
struct GoalShapeRow<Glyph: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let style: GoalStatusStyle
    /// The headline figure; empty for a goal measured by kind, which only has a next step to say.
    let value: String
    let caption: String
    @ViewBuilder let glyph: Glyph

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Label {
                    Text(title).font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                } icon: {
                    Image(systemName: icon).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(tint)
                }
                Spacer(minLength: NoopMetrics.space1)
                Label(style.wordText, systemImage: style.symbol)
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(style.foreground)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                if !value.isEmpty {
                    Text(value).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit().lineLimit(1)
                }
                Text(caption).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            glyph
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
