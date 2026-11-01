import Foundation
import StrandCore
import StrandImport

/// Fork (DX23876): Android's GPX/FIT route export through the Swift `RouteExporter`, so a file from Android
/// carries what one from iOS does: the measured point times and heights, and in a FIT the session's
/// heart-rate curve read from the devices the workout's chart plots (`WorkoutPhysiology.samples`). The Kotlin
/// `RouteExport` stays as the fallback for a process without the core.
enum CoreRouteExport {
    static func run(_ args: [String: Any], reader: StoreReader) async -> String {
        func int(_ k: String) -> Int? { (args[k] as? NSNumber)?.intValue }
        func double(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        guard let format = RouteExporter.Format(rawValue: args["format"] as? String ?? ""),
              let path = args["path"] as? String, !path.isEmpty,
              let startTs = int("startTs"), let endTs = int("endTs") else { return #"{"error":"invalid"}"# }
        let lat = (args["lat"] as? [NSNumber])?.map(\.doubleValue) ?? []
        let lon = (args["lon"] as? [NSNumber])?.map(\.doubleValue) ?? []
        guard lat.count == lon.count else { return #"{"error":"invalid"}"# }
        let route = zip(lat, lon).map { RoutePoint(lat: $0, lon: $1) }
        // Times and heights only when they belong to every point; a mismatched array is ignored, as on iOS.
        let times = (args["timesMs"] as? [NSNumber]).map { $0.map { Int($0.int64Value / 1000) } }
        let heights = (args["altitudes"] as? [Any]).map { $0.map { ($0 as? NSNumber)?.doubleValue } }
        let source = args["source"] as? String ?? ""
        let pulse = format == .fit
            ? await WorkoutPhysiology.samples(reader: reader, from: startTs, to: endTs, source: source)
                .map { ActivityHRSample(ts: $0.ts, bpm: $0.bpm) }
            : []
        let data = RouteExporter.render(
            format, route: route, startTs: startTs, endTs: endTs, sport: args["sport"] as? String,
            distanceM: double("distanceM"), energyKcal: double("energyKcal"), avgHr: int("avgHr"), maxHr: int("maxHr"),
            recordedTimes: times?.count == route.count ? times : nil,
            elevations: heights?.count == route.count ? heights : nil,
            heartRate: pulse)
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return #"{"ok":true}"#
        } catch {
            return #"{"error":"writeFailed"}"#
        }
    }
}
