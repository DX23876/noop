import Foundation

// MARK: - Grade along a route, as gpx.studio computes it
//
// A faithful port of gpx.studio (MIT License, https://github.com/gpxstudio/gpx.studio), `gpx/src/gpx.ts`:
// the per-point `slope.at` and its `windowSmoothing` / `distanceWindowSmoothing` helpers. For each point
// the window reaches back while the distance to it exceeds 50 m and forward while it stays within 50 m,
// always at least one point on either side; the grade is the height difference across the window over the
// distance along the route. Their constants are in kilometres (0.05) and percent (0.1 · m / km); here the
// window is 50 m and the grade a fraction (0.05 = 5 %).
//
// The heights fed in are the barometer's, which are smooth to decimetres; gpx.studio applies the same
// window to whatever elevation a file carries.

public enum ElevationProfile {

    /// gpx.studio's slope window: 0.05 km either side of the point.
    public static let slopeWindowM = 50.0

    /// The grade at every point, a fraction. `distancesM` is the cumulative distance along the route,
    /// one per height. A window with no distance gives 0, as in gpx.studio.
    public static func grades(distancesM: [Double], elevationsM: [Double]) -> [Double] {
        let count = min(distancesM.count, elevationsM.count)
        guard count > 0 else { return [] }
        var out = Array(repeating: 0.0, count: count)
        windowSmoothing(left: 0, right: count,
                        distance: { distancesM[$1] - distancesM[$0] },
                        window: slopeWindowM) { start, end in
            let ele = elevationsM[end] - elevationsM[start]
            let dist = distancesM[end] - distancesM[start]
            return dist > 0 && ele.isFinite ? ele / dist : 0
        } callback: { value, index in
            out[index] = value
        }
        return out
    }

    /// gpx.studio `windowSmoothing`.
    static func windowSmoothing(left: Int, right: Int, distance: (Int, Int) -> Double, window: Double,
                                compute: (Int, Int) -> Double, callback: (Double, Int) -> Void) {
        var start = left
        var i = left
        while i < right {
            while start + 1 < i && distance(start, i) > window {
                start += 1
            }
            var end = min(i + 2, right)
            while end < right && distance(i, end) <= window {
                end += 1
            }
            callback(compute(start, end - 1), i)
            i += 1
        }
    }
}

// MARK: - Energy cost of walking and running on a slope (Minetti et al. 2002)
//
// Minetti AE, Moia C, Roi GS, Susta D, Ferretti G. Energy cost of walking and running at extreme uphill
// and downhill slopes. J Appl Physiol 93: 1039–1046, 2002. Fifth-order fits to the measured cost per metre
// (J · kg⁻¹ · m⁻¹) at gradient i, valid for −0.45 ≤ i ≤ +0.45 (R² 0.999 each):
//
//   Cw(i) = 280.5 i⁵ − 58.7 i⁴ − 76.8 i³ + 51.9 i² + 19.6 i + 2.5
//   Cr(i) = 155.4 i⁵ − 30.4 i⁴ − 43.3 i³ + 46.3 i² + 19.5 i + 3.6
//
// Running cost per metre does not depend on speed (the paper's finding), so a route stretch of length d on
// gradient i costs what d · Cr(i) / Cr(0) metres cost on the flat. That flat-equivalent distance is what a
// grade-adjusted pace divides time by. Walking cost was measured at the most economical speed for each
// slope, so for walking the same ratio is that optimum's, which the screen says.

public enum MinettiCost {

    /// The gradients the fits were measured over; outside them the polynomials are not data.
    public static let validGrade: ClosedRange<Double> = -0.45...0.45

    /// Cw(i), J · kg⁻¹ · m⁻¹. The gradient is clamped to `validGrade`.
    public static func walking(grade: Double) -> Double {
        let i = clamp(grade)
        let i2 = i * i, i3 = i2 * i, i4 = i3 * i, i5 = i4 * i
        let high: Double = 280.5 * i5 - 58.7 * i4 - 76.8 * i3
        let low: Double = 51.9 * i2 + 19.6 * i + 2.5
        return high + low
    }

    /// Cr(i), J · kg⁻¹ · m⁻¹. The gradient is clamped to `validGrade`.
    public static func running(grade: Double) -> Double {
        let i = clamp(grade)
        let i2 = i * i, i3 = i2 * i, i4 = i3 * i, i5 = i4 * i
        let high: Double = 155.4 * i5 - 30.4 * i4 - 43.3 * i3
        let low: Double = 46.3 * i2 + 19.5 * i + 3.6
        return high + low
    }

    public static func cost(grade: Double, gait: ExerciseVO2max.Gait) -> Double {
        gait == .walking ? walking(grade: grade) : running(grade: grade)
    }

    /// How many flat metres one metre on `grade` costs.
    public static func flatEquivalentFactor(grade: Double, gait: ExerciseVO2max.Gait) -> Double {
        cost(grade: grade, gait: gait) / cost(grade: 0, gait: gait)
    }

    private static func clamp(_ grade: Double) -> Double {
        guard grade.isFinite else { return 0 }
        return min(max(grade, validGrade.lowerBound), validGrade.upperBound)
    }
}

// MARK: - Grade-adjusted pace over a recorded route

/// One measured point of a recorded route, as the grade and the grade-adjusted pace read it.
public struct ElevationTrackPoint: Equatable, Sendable {
    /// Cumulative distance along the route, metres.
    public let distanceM: Double
    /// Active workout seconds (pauses excluded).
    public let seconds: Double
    /// Barometric height, metres; comparable only within one `segment`.
    public let elevationM: Double?
    public let segment: Int

    public init(distanceM: Double, seconds: Double, elevationM: Double?, segment: Int) {
        self.distanceM = distanceM; self.seconds = seconds; self.elevationM = elevationM; self.segment = segment
    }
}

public enum GradeAdjustedPace {

    /// The grade of every point, a fraction, by gpx.studio's window run separately on each segment so no
    /// grade spans a gap. nil for a point whose segment has no height.
    public static func grades(_ points: [ElevationTrackPoint]) -> [Double?] {
        var out = [Double?](repeating: nil, count: points.count)
        var start = 0
        while start < points.count {
            var end = start
            while end + 1 < points.count, points[end + 1].segment == points[start].segment { end += 1 }
            let run = Array(points[start...end])
            if run.allSatisfy({ $0.elevationM?.isFinite == true }) {
                let grades = ElevationProfile.grades(distancesM: run.map(\.distanceM),
                                                     elevationsM: run.map { $0.elevationM ?? 0 })
                for (offset, grade) in grades.enumerated() { out[start + offset] = grade }
            }
            start = end + 1
        }
        return out
    }

    /// Flat-equivalent distance between two active times: every leg inside one segment counts its length
    /// times Minetti's cost ratio at the grade of its two ends. nil when a leg in range has no grade.
    public static func flatEquivalentMeters(_ points: [ElevationTrackPoint], grades: [Double?],
                                            gait: ExerciseVO2max.Gait,
                                            from: Double, to: Double) -> Double? {
        guard points.count == grades.count, to > from else { return nil }
        var total = 0.0
        var legs = 0
        for index in points.indices.dropFirst() {
            let a = points[index - 1], b = points[index]
            guard a.segment == b.segment, b.seconds > from, a.seconds < to else { continue }
            guard let ga = grades[index - 1], let gb = grades[index] else { return nil }
            let length = max(0, b.distanceM - a.distanceM)
            // A leg crossing a section boundary counts the share of it that lies inside.
            let span = b.seconds - a.seconds
            let inside = span > 0 ? (min(b.seconds, to) - max(a.seconds, from)) / span : 1
            total += length * max(0, min(1, inside))
                * MinettiCost.flatEquivalentFactor(grade: (ga + gb) / 2, gait: gait)
            legs += 1
        }
        return legs > 0 ? total : nil
    }

    /// Seconds per kilometre on the flat for the same effort, between two active times.
    public static func paceSecPerKm(_ points: [ElevationTrackPoint], grades: [Double?],
                                    gait: ExerciseVO2max.Gait, from: Double, to: Double) -> Double? {
        guard let meters = flatEquivalentMeters(points, grades: grades, gait: gait, from: from, to: to),
              meters > 0 else { return nil }
        return (to - from) / meters * 1000
    }

    /// The steepest grade up and down over the route, fractions; nil without heights.
    public static func extremes(_ grades: [Double?]) -> (maxUp: Double, maxDown: Double)? {
        let known = grades.compactMap { $0 }
        guard let high = known.max(), let low = known.min() else { return nil }
        return (max(0, high), min(0, low))
    }
}
