import Foundation
import StrandAnalytics

/// A route's heights prepared for the profile, the grade and the grade-adjusted pace.
///
/// Heights come from the barometer when the points carry one (smooth to decimetres), lifted to sea level by
/// the median offset to Apple's absolute altitude where both are known; a route imported from Apple Health
/// carries Apple's altitude only and uses it as it is. Points without a usable height are left out, and
/// distance runs along the route within a segment only, so a gap never reads as a climb or a straight line.
struct WorkoutElevationSeries: Equatable {
    /// Distance, active seconds and the height the grade is read from, one per kept point.
    let track: [ElevationTrackPoint]
    /// The height to draw for each point of `track`.
    let heights: [Double]
    /// gpx.studio's grade at each point, per segment.
    let grades: [Double?]
    /// True when `heights` are above sea level; false when only relative to the start.
    let isAbsolute: Bool

    var totalDistanceM: Double { track.last?.distanceM ?? 0 }

    static func make(points: [WorkoutRoutePoint]) -> WorkoutElevationSeries? {
        let usesBarometer = points.contains { $0.baroAltitudeM != nil }
        let kept = points.filter {
            let height = usesBarometer ? $0.baroAltitudeM : $0.altitudeM
            return height?.isFinite == true && $0.lat.isFinite && $0.lon.isFinite
        }
        guard kept.count >= 2, let firstMs = kept.first?.tMs else { return nil }
        var track: [ElevationTrackPoint] = []
        var distance = 0.0
        for (index, point) in kept.enumerated() {
            if index > 0, (point.segment ?? 0) == (kept[index - 1].segment ?? 0) {
                distance += RouteMath.haversineMeters(RouteMath.LatLng(kept[index - 1].lat, kept[index - 1].lon),
                                                      RouteMath.LatLng(point.lat, point.lon))
            }
            let height = (usesBarometer ? point.baroAltitudeM : point.altitudeM) ?? 0
            track.append(ElevationTrackPoint(distanceM: distance,
                                             seconds: point.activeSeconds ?? Double(point.tMs - firstMs) / 1000,
                                             elevationM: height, segment: point.segment ?? 0))
        }
        var heights = track.map { $0.elevationM ?? 0 }
        var absolute = !usesBarometer
        if usesBarometer {
            let offsets = kept.compactMap { point -> Double? in
                guard let a = point.altitudeM, let b = point.baroAltitudeM, a.isFinite else { return nil }
                return a - b
            }.sorted()
            if !offsets.isEmpty {
                let median = offsets[offsets.count / 2]
                heights = heights.map { $0 + median }
                absolute = true
            } else if let first = heights.first {
                heights = heights.map { $0 - first }
            }
        }
        return WorkoutElevationSeries(track: track, heights: heights, grades: GradeAdjustedPace.grades(track),
                                      isAbsolute: absolute)
    }

    /// At most `maxPoints` evenly spaced samples for drawing: distance, height and grade.
    func drawable(maxPoints: Int = 240) -> [(distanceM: Double, heightM: Double, grade: Double)] {
        guard !track.isEmpty else { return [] }
        let step = max(1, Int((Double(track.count) / Double(max(2, maxPoints))).rounded(.up)))
        var indices = Array(stride(from: 0, to: track.count, by: step))
        if indices.last != track.count - 1 { indices.append(track.count - 1) }
        return indices.map { (track[$0].distanceM, heights[$0], grades[$0] ?? 0) }
    }

    /// The grade over the last stretch: gpx.studio's window at the newest point.
    var currentGrade: Double? { grades.last ?? nil }

    /// Grade-adjusted pace between two active times, for walking or running only.
    func gradeAdjustedPace(gait: ExerciseVO2max.Gait, from: Double, to: Double) -> Double? {
        GradeAdjustedPace.paceSecPerKm(track, grades: grades, gait: gait, from: from, to: to)
    }

    /// Grade-adjusted pace over the whole route: each segment's moving time over its flat-equivalent
    /// distance, so the time spent in a measurement gap is not charged to any metre.
    func wholeGradeAdjustedPace(gait: ExerciseVO2max.Gait) -> Double? {
        var seconds = 0.0, meters = 0.0
        var start = 0
        while start < track.count {
            var end = start
            while end + 1 < track.count, track[end + 1].segment == track[start].segment { end += 1 }
            let from = track[start].seconds, to = track[end].seconds
            if to > from, let flat = GradeAdjustedPace.flatEquivalentMeters(track, grades: grades, gait: gait,
                                                                            from: from, to: to) {
                seconds += to - from
                meters += flat
            }
            start = end + 1
        }
        return meters > 0 ? seconds / meters * 1000 : nil
    }

    /// The Minetti curve a sport is adjusted with: running for runs, walking for walks and hikes; nil for
    /// any other sport, which shows no grade-adjusted pace.
    static func gait(forSport sport: String) -> ExerciseVO2max.Gait? {
        switch sport {
        case "Running", "Treadmill run", "Trail running": return .running
        case "Walking", "Hiking", "Treadmill walk", "Nordic walking", "Rucking": return .walking
        default: return nil
        }
    }
}
