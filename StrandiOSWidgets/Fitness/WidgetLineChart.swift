import SwiftUI
import WidgetKit
import StrandDesign

/// A short trend as a line: the wearer's usual range as a soft band behind it, today's value as a dot.
/// Days without a value leave a gap rather than a made-up line.
struct WidgetLineChart: View {
    let values: [Double?]
    var usual: FitnessWidgetSnapshot.Usual?
    let tint: Color
    let fullColor: Bool

    var body: some View {
        Canvas { context, size in
            let present = values.compactMap { $0 }
            guard !present.isEmpty else { return }
            var low = present.min() ?? 0, high = present.max() ?? 1
            if let usual { low = min(low, usual.low); high = max(high, usual.high) }
            // A margin of the data's own spread, so a flat month of weigh-ins still shows its shape.
            let pad = max((high - low) * 0.15, 0.1)
            low -= pad; high += pad
            let inset: CGFloat = 5
            func y(_ v: Double) -> CGFloat {
                inset + (size.height - 2 * inset) * CGFloat(1 - (v - low) / (high - low))
            }
            func x(_ i: Int) -> CGFloat {
                values.count < 2 ? size.width / 2 : inset + (size.width - 2 * inset) * CGFloat(i) / CGFloat(values.count - 1)
            }
            if let usual {
                let rect = CGRect(x: 0, y: y(usual.high), width: size.width, height: y(usual.low) - y(usual.high))
                context.fill(Path(roundedRect: rect, cornerRadius: 4),
                             with: .color(fullColor ? tint.opacity(0.15) : Color.primary.opacity(0.15)))
            }
            var line = Path()
            var open = false
            for (i, value) in values.enumerated() {
                guard let value else { open = false; continue }
                let point = CGPoint(x: x(i), y: y(value))
                if open { line.addLine(to: point) } else { line.move(to: point) }
                open = true
            }
            let stroke = fullColor ? tint : Color.primary
            context.stroke(line, with: .color(stroke), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let lastIndex = values.lastIndex(where: { $0 != nil }), let last = values[lastIndex] {
                let p = CGPoint(x: x(lastIndex), y: y(last))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(stroke))
            }
        }
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
