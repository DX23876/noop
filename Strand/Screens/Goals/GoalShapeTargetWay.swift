import SwiftUI
import StrandDesign

/// The way from the start to the target: a track filled to the latest measurement, a tick per waypoint,
/// an open circle at the target.
struct GoalShapeTargetWay: View {
    let progress: Double
    let marks: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let end = size.width - 5
            let x = 3 + (end - 3) * min(1, max(0, progress))
            var track = Path()
            track.move(to: CGPoint(x: 3, y: mid))
            track.addLine(to: CGPoint(x: end, y: mid))
            context.stroke(track, with: .color(StrandPalette.textTertiary.opacity(0.3)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            for mark in marks {
                let mx = 3 + (end - 3) * mark
                var tick = Path()
                tick.move(to: CGPoint(x: mx, y: mid - 4))
                tick.addLine(to: CGPoint(x: mx, y: mid + 4))
                context.stroke(tick, with: .color(mx <= x ? tint : StrandPalette.textTertiary), lineWidth: 1.5)
            }
            var done = Path()
            done.move(to: CGPoint(x: 3, y: mid))
            done.addLine(to: CGPoint(x: x, y: mid))
            context.stroke(done, with: .color(tint), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            context.stroke(Path(ellipseIn: CGRect(x: end - 4, y: mid - 4, width: 8, height: 8)),
                           with: .color(StrandPalette.textPrimary), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: x - 5, y: mid - 5, width: 10, height: 10)), with: .color(tint))
        }
        .frame(height: GoalShapeGlyph.height)
    }
}
