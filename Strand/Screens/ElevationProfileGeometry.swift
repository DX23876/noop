import SwiftUI

/// The profile's samples laid out once in a 0…1 unit space, with the height range and the grade colours,
/// so a redraw or a scrub never recomputes them.
struct ElevationProfileGeometry {
    let samples: [(distanceM: Double, heightM: Double, grade: Double)]
    /// The drawn height range, with headroom so a flat walk does not fill the card with its own noise.
    let low: Double
    let high: Double
    let totalDistanceM: Double
    /// Each sample at x = distance share, y = 0 at the top of the range.
    let points: [CGPoint]
    let gradeStops: [Gradient.Stop]

    init(samples: [(distanceM: Double, heightM: Double, grade: Double)]) {
        self.samples = samples
        let heights = samples.map(\.heightM)
        let minHeight = heights.min() ?? 0, maxHeight = heights.max() ?? 0
        // Five metres either side at least: ten metres of range for a flat route.
        let pad = max(5, (maxHeight - minHeight) * 0.15)
        let bottom = minHeight - pad, top = maxHeight + pad
        let total = max(1, samples.last?.distanceM ?? 1)
        let span = max(1, top - bottom)
        low = bottom
        high = top
        totalDistanceM = total
        points = samples.map { CGPoint(x: $0.distanceM / total, y: 1 - ($0.heightM - bottom) / span) }
        gradeStops = samples.count > 1
            ? samples.map { Gradient.Stop(color: ElevationGradeStyle.color(forGrade: $0.grade),
                                          location: $0.distanceM / total) }
            : [Gradient.Stop(color: ElevationGradeStyle.color(forGrade: 0), location: 0)]
    }

    /// The sample nearest a horizontal share of the plot, for the scrub readout.
    func nearestIndex(toShare share: Double) -> Int? {
        let target = min(max(0, share), 1) * totalDistanceM
        return samples.indices.min { abs(samples[$0].distanceM - target) < abs(samples[$1].distanceM - target) }
    }
}
