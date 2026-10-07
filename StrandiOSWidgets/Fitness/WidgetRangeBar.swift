import SwiftUI
import WidgetKit
import StrandDesign

/// A value against the wearer's usual range: the range as a band in the middle of the track, the
/// value as a dot. A value outside the band sits beyond it, at most at the track's end.
struct WidgetRangeBar: View {
    let value: Double
    let usual: FitnessWidgetSnapshot.Usual
    let tint: Color
    let fullColor: Bool

    var body: some View {
        Canvas { context, size in
            let span = max(usual.high - usual.low, 0.0001)
            let low = usual.low - span, high = usual.high + span
            func x(_ v: Double) -> CGFloat {
                5 + (size.width - 10) * CGFloat(min(1, max(0, (v - low) / (high - low))))
            }
            let mid = size.height / 2
            let track = fullColor ? StrandPalette.textTertiary.opacity(0.3) : Color.primary.opacity(0.3)
            context.fill(Path(roundedRect: CGRect(x: 0, y: mid - 2, width: size.width, height: 4), cornerRadius: 2),
                         with: .color(track))
            context.fill(Path(roundedRect: CGRect(x: x(usual.low), y: mid - 4, width: x(usual.high) - x(usual.low), height: 8),
                              cornerRadius: 4),
                         with: .color((fullColor ? tint : .primary).opacity(0.3)))
            let px = x(value)
            context.fill(Path(ellipseIn: CGRect(x: px - 5, y: mid - 5, width: 10, height: 10)),
                         with: .color(fullColor ? tint : .primary))
        }
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
