import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

/// One builder for a workout's GPX or FIT file, used by the workout detail's share buttons and by the
/// Shortcuts action, so the two exports of one workout cannot carry different data.
///
/// It reads everything itself from the row's own sources: the recorded segments or the stored polyline for
/// the track, the measured point times and heights where they belong to every point, the recorded pauses,
/// and for a FIT the session's raw heart rate from the devices the curve card plots
/// (`Repository.workoutHrSamples`). A workout without a route still makes a FIT from its heart rate; GPX
/// has nothing to say without a track.
enum WorkoutFileExport {

    /// The file name: `noop-route-<start>` for a track, `noop-workout-<start>` for a file without one.
    static func fileName(_ format: RouteExporter.Format, row: WorkoutRow, hasRoute: Bool) -> String {
        "\(hasRoute ? "noop-route" : "noop-workout")-\(row.startTs).\(format.ext)"
    }

    /// The file's bytes and name, or nil when there is nothing to put in it.
    static func build(_ format: RouteExporter.Format, row: WorkoutRow,
                      repo: Repository) async -> (data: Data, name: String)? {
        let recordings = (try? await repo.workoutRecordings(for: row)) ?? []
        let segments = recordings.flatMap { $0.route?.segments ?? [] }
        let track: [RouteMath.LatLng] = {
            if !segments.isEmpty { return segments.flatMap { $0 } }
            guard let stored = RouteStore.load(startTs: row.startTs, sport: row.sport) else { return [] }
            let points = RouteMath.decode(stored.polyline)
            return points.count >= 2 ? points : []
        }()
        let recorded = recordings.flatMap { $0.route?.points ?? [] }
        let measured = recorded.isEmpty
            ? (RouteStore.loadWithPoints(startTs: row.startTs, sport: row.sport)?.points ?? [])
            : recorded
        let aligned = measured.count == track.count && !track.isEmpty
        var offset = 0
        let boundaries = segments.map { segment in
            defer { offset += segment.count }
            return offset
        }
        let pauses = recordings.flatMap { $0.timeline.pauses ?? [] }.map {
            RouteExporter.Pause(start: Int($0.startUnixSeconds), end: Int($0.endUnixSeconds ?? Double(row.endTs)))
        }
        let pulse = format == .fit
            ? await repo.workoutHrSamples(from: row.startTs, to: row.endTs, source: row.source)
                .map { ActivityHRSample(ts: $0.ts, bpm: $0.bpm) }
            : []
        guard track.count >= 2 || (format == .fit && !pulse.isEmpty) else { return nil }
        let data = RouteExporter.render(
            format, route: track.map { RoutePoint(lat: $0.lat, lon: $0.lon) },
            startTs: row.startTs, endTs: row.endTs, sport: row.sport,
            distanceM: row.distanceM, energyKcal: row.energyKcal, avgHr: row.avgHr, maxHr: row.maxHr,
            recordedTimes: aligned ? measured.map { Int($0.tMs / 1000) } : nil,
            segmentStarts: boundaries,
            activeDurationS: recordings.isEmpty ? nil : row.durationS,
            elevations: aligned ? measured.map(\.altitudeM) : nil,
            heartRate: pulse, pauses: pauses)
        return (data, fileName(format, row: row, hasRoute: track.count >= 2))
    }
}
