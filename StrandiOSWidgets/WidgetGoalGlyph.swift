import SwiftUI
import WidgetKit
import StrandDesign

/// A goal's shape in the widget, drawn from the app's `GoalWidgetSnapshot.Glyph`: the same lines as
/// Today's goals card (a track with the plan's mark, the way to a target, week or day dots, columns, a
/// band). One `Canvas` per shape keeps the extension inside its memory budget. In the tinted and clear
/// modes everything is drawn in the primary colour with stronger contrast, so it reads without colour.
struct WidgetGoalGlyph: View {
    let glyph: GoalWidgetSnapshot.Glyph
    let tint: Color
    let fullColor: Bool

    static let height: CGFloat = 12

    private var track: Color { fullColor ? StrandPalette.textTertiary.opacity(0.28) : Color.primary.opacity(0.25) }
    private var fill: Color { fullColor ? tint : .primary }

    var body: some View {
        Canvas { context, size in
            switch glyph.kind {
            case "track": drawTrack(context, size)
            case "way": drawWay(context, size)
            case "weeks", "days": drawDots(context, size)
            case "columns": drawColumns(context, size)
            case "band": drawBand(context, size)
            default: break
            }
        }
        .frame(height: Self.height)
        .widgetAccentable()
        .accessibilityHidden(true)
    }

    private func clamp(_ v: Double?) -> CGFloat { CGFloat(min(1, max(0, v ?? 0))) }

    private func drawTrack(_ context: GraphicsContext, _ size: CGSize) {
        let h: CGFloat = 5, y = (size.height - h) / 2
        context.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: h), cornerRadius: h / 2),
                     with: .color(track))
        let w = size.width * clamp(glyph.fraction)
        if w > 0 {
            context.fill(Path(roundedRect: CGRect(x: 0, y: y, width: max(h, w), height: h), cornerRadius: h / 2),
                         with: .color(fill))
        }
        if let pace = glyph.paceFraction, (glyph.fraction ?? 0) < 1 {
            let x = min(size.width - 2, max(0, size.width * clamp(pace) - 1))
            context.fill(Path(CGRect(x: x, y: 0, width: fullColor ? 2 : 3, height: size.height)),
                         with: .color(.primary))
        }
    }

    private func drawWay(_ context: GraphicsContext, _ size: CGSize) {
        let mid = size.height / 2, start: CGFloat = 3, end = size.width - 5
        let x = start + (end - start) * clamp(glyph.fraction)
        var line = Path()
        line.move(to: CGPoint(x: start, y: mid))
        line.addLine(to: CGPoint(x: end, y: mid))
        context.stroke(line, with: .color(track), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        for mark in glyph.marks ?? [] {
            let mx = start + (end - start) * clamp(mark)
            var tick = Path()
            tick.move(to: CGPoint(x: mx, y: mid - 4))
            tick.addLine(to: CGPoint(x: mx, y: mid + 4))
            context.stroke(tick, with: .color(mx <= x ? fill : track), lineWidth: 1.5)
        }
        var done = Path()
        done.move(to: CGPoint(x: start, y: mid))
        done.addLine(to: CGPoint(x: x, y: mid))
        context.stroke(done, with: .color(fill), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        context.stroke(Path(ellipseIn: CGRect(x: end - 4, y: mid - 4, width: 8, height: 8)),
                       with: .color(.primary), lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: x - 5, y: mid - 5, width: 10, height: 10)), with: .color(fill))
    }

    /// Week or day dots: filled when kept or met, an empty ring when missed, dashed without data.
    private func drawDots(_ context: GraphicsContext, _ size: CGSize) {
        let states = glyph.states ?? []
        let d: CGFloat = 10, gap: CGFloat = 4, y = (size.height - d) / 2
        for (i, state) in states.enumerated() {
            let rect = CGRect(x: CGFloat(i) * (d + gap), y: y, width: d, height: d)
            guard rect.maxX <= size.width else { break }
            let circle = Path(ellipseIn: rect)
            let inner = Path(ellipseIn: rect.insetBy(dx: 0.75, dy: 0.75))
            switch state {
            case "achieved", "met", "todayMet":
                context.fill(circle, with: .color(fill))
            case "almost":
                context.fill(circle, with: .color(fill.opacity(0.4)))
                context.stroke(inner, with: .color(fill), lineWidth: 1.5)
            case "today":
                context.stroke(inner, with: .color(.primary), lineWidth: 1.5)
            case "noData":
                context.stroke(inner, with: .color(track), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            case "future", "rest":
                context.fill(circle, with: .color(track))
            default: // missed, protected
                context.stroke(inner, with: .color(fullColor ? StrandPalette.textTertiary : .primary.opacity(0.5)),
                               lineWidth: 1.5)
            }
        }
    }

    private func drawColumns(_ context: GraphicsContext, _ size: CGSize) {
        let values = glyph.values ?? []
        guard !values.isEmpty, let target = glyph.target, target > 0 else { return }
        let top = max(target * 1.25, (values.compactMap { $0 }.max() ?? 0) * 1.05)
        let gap: CGFloat = 2
        let w = max(1, (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))
        for (i, value) in values.enumerated() {
            guard let value else { continue }
            let h = max(1, size.height * CGFloat(value / top))
            let met = (glyph.higherIsBetter ?? true) ? value >= target : value <= target
            context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * (w + gap), y: size.height - h, width: w, height: h),
                              cornerRadius: 1),
                         with: .color(met ? fill : fill.opacity(0.45)))
        }
        let ty = size.height - size.height * CGFloat(target / top)
        var line = Path()
        line.move(to: CGPoint(x: 0, y: ty))
        line.addLine(to: CGPoint(x: size.width, y: ty))
        context.stroke(line, with: .color(.primary), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }

    private func drawBand(_ context: GraphicsContext, _ size: CGSize) {
        let mid = size.height / 2
        var line = Path()
        line.move(to: CGPoint(x: 5, y: mid))
        line.addLine(to: CGPoint(x: size.width - 5, y: mid))
        context.stroke(line, with: .color(track), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let span = size.width - 10
        let a = 5 + span * clamp(glyph.bandLow), b = 5 + span * clamp(glyph.bandHigh)
        context.fill(Path(roundedRect: CGRect(x: a, y: mid - 4, width: max(2, b - a), height: 8), cornerRadius: 4),
                     with: .color(fill.opacity(0.3)))
        if let latest = glyph.latest {
            let x = 5 + span * clamp(latest)
            context.fill(Path(ellipseIn: CGRect(x: x - 5, y: mid - 5, width: 10, height: 10)), with: .color(fill))
        }
    }
}
