import SwiftUI

/// The profile as a line, or closed to the bottom edge as an area, from points in a 0…1 unit space.
struct ElevationProfileShape: Shape {
    let points: [CGPoint]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
        if closed {
            path.move(to: CGPoint(x: map(first).x, y: rect.maxY))
            path.addLine(to: map(first))
        } else {
            path.move(to: map(first))
        }
        for point in points.dropFirst() { path.addLine(to: map(point)) }
        if closed {
            path.addLine(to: CGPoint(x: map(last).x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
