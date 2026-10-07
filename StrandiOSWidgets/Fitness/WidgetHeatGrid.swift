import SwiftUI
import WidgetKit
import StrandDesign

/// Active days as a calendar grid, one column per week, oldest week first, days top to bottom: filled
/// when active, an empty cell when not, a dashed cell without any record. The grid ends at today, so the
/// last column may be shorter.
struct WidgetHeatGrid: View {
    let days: [Bool?]
    let tint: Color
    let fullColor: Bool

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }
            let weeks = Int((Double(days.count) / 7).rounded(.up))
            let gap: CGFloat = 3
            let cell = min((size.width - gap * CGFloat(weeks - 1)) / CGFloat(weeks),
                           (size.height - gap * 6) / 7)
            let muted = fullColor ? StrandPalette.textTertiary : Color.primary.opacity(0.5)
            for (i, day) in days.enumerated() {
                let rect = CGRect(x: CGFloat(i / 7) * (cell + gap), y: CGFloat(i % 7) * (cell + gap),
                                  width: cell, height: cell)
                let shape = Path(roundedRect: rect, cornerRadius: cell * 0.25)
                switch day {
                case true?: context.fill(shape, with: .color(fullColor ? tint : .primary))
                case false?: context.fill(shape, with: .color(muted.opacity(0.3)))
                case nil: context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cell * 0.25),
                                         with: .color(muted.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
        }
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
