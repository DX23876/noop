import SwiftUI

// MARK: - ForgeMark — the NOOP Forge "F"

/// The "F" from the NOOP Forge app icon, drawn as vector shapes so it stays crisp at any size.
///
/// Two slanted strokes: the upper bar with its stem, and the lower bar whose right face carries the brand
/// ember. The ink follows `StrandPalette.textPrimary`, so the mark flips with the theme like any other text.
/// Geometry lives in a 400 × 410 box and is scaled to `size` (the mark's height).
public struct ForgeMark: View {

    /// Height of the mark in points; the width follows from the 400 × 410 design box.
    public var size: CGFloat

    public init(size: CGFloat = 24) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            ForgeMarkShape(points: Self.upper).fill(StrandPalette.textPrimary)
            ForgeMarkShape(points: Self.lower).fill(StrandPalette.textPrimary)
            ForgeMarkShape(points: Self.arm).fill(StrandPalette.forgeEmber)
        }
        .frame(width: size * Self.box.width / Self.box.height, height: size)
        .accessibilityLabel(Text(verbatim: "NOOP Forge"))
    }

    static let box = CGSize(width: 400, height: 410)
    static let upper: [CGPoint] = [.init(x: 152, y: 0), .init(x: 400, y: 0), .init(x: 330, y: 100),
                                   .init(x: 150, y: 100), .init(x: 0, y: 275), .init(x: 0, y: 152)]
    static let lower: [CGPoint] = [.init(x: 124, y: 160), .init(x: 350, y: 160), .init(x: 280, y: 262),
                                   .init(x: 127, y: 262), .init(x: 0, y: 410), .init(x: 0, y: 305)]
    static let arm: [CGPoint] = [.init(x: 210, y: 160), .init(x: 350, y: 160), .init(x: 280, y: 262),
                                 .init(x: 123, y: 262)]
}

/// One stroke of the mark: a polygon in the 400 × 410 design box with slightly rounded corners.
struct ForgeMarkShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / ForgeMark.box.width
        let sy = rect.height / ForgeMark.box.height
        let pts = points.map { CGPoint(x: rect.minX + $0.x * sx, y: rect.minY + $0.y * sy) }
        let radius = 10 * min(sx, sy)
        var path = Path()
        guard let first = pts.first, let last = pts.last else { return path }
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for i in pts.indices {
            path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % pts.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

#Preview("ForgeMark — sizes") {
    HStack(spacing: 24) {
        ForgeMark(size: 120)
        ForgeMark(size: 44)
        ForgeMark(size: 22)
    }
    .padding()
}
