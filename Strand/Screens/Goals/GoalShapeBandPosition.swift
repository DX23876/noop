import SwiftUI
import StrandDesign

/// Holding a value: the band around the middle, tinted, and a dot for the latest reading. The track runs
/// one band width past each edge so a reading outside still has a place.
struct GoalShapeBandPosition: View {
    let latest: Double?
    let center: Double
    let band: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard band > 0 else { return }
            let mid = size.height / 2
            let low = center - 2 * band, span = 4 * band
            func xFor(_ v: Double) -> CGFloat { 5 + (size.width - 10) * CGFloat(min(1, max(0, (v - low) / span))) }
            var track = Path()
            track.move(to: CGPoint(x: 5, y: mid))
            track.addLine(to: CGPoint(x: size.width - 5, y: mid))
            context.stroke(track, with: .color(StrandPalette.textTertiary.opacity(0.28)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let a = xFor(center - band), b = xFor(center + band)
            context.fill(Path(roundedRect: CGRect(x: a, y: mid - 4, width: b - a, height: 8), cornerRadius: 4),
                         with: .color(tint.opacity(0.3)))
            if let latest {
                let x = xFor(latest)
                context.fill(Path(ellipseIn: CGRect(x: x - 5, y: mid - 5, width: 10, height: 10)), with: .color(tint))
            }
        }
        .frame(height: GoalShapeGlyph.height)
    }
}
