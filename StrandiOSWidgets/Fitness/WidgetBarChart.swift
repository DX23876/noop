import SwiftUI
import WidgetKit
import StrandDesign

/// Daily bars, oldest first, with an optional goal line. Each bar takes its own colour (a Charge or an
/// Effort day keeps its zone colour); a day without a value is a short empty stub, not a zero.
struct WidgetBarChart: View {
    let values: [Double?]
    /// The top of the scale; the largest value (or the goal) when nil.
    var maximum: Double?
    var goal: Double?
    let color: (Int, Double) -> Color
    let fullColor: Bool

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let top = max(maximum ?? 0, goal.map { $0 * 1.1 } ?? 0, values.compactMap { $0 }.max() ?? 0, 1)
            let gap: CGFloat = 4
            let w = max(2, (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))
            let track = fullColor ? StrandPalette.textTertiary.opacity(0.3) : Color.primary.opacity(0.3)
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * (w + gap)
                guard let value else {
                    context.fill(Path(roundedRect: CGRect(x: x, y: size.height - 3, width: w, height: 3), cornerRadius: 1.5),
                                 with: .color(track))
                    continue
                }
                let h = max(3, size.height * CGFloat(value / top))
                context.fill(Path(roundedRect: CGRect(x: x, y: size.height - h, width: w, height: h),
                                  cornerRadius: min(4, w / 2)),
                             with: .color(fullColor ? color(i, value) : Color.primary))
            }
            if let goal {
                let gy = size.height - size.height * CGFloat(goal / top)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: gy))
                line.addLine(to: CGPoint(x: size.width, y: gy))
                context.stroke(line, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
