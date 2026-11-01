#if os(iOS)
import Foundation
import AppIntents
import StrandImport
import WhoopStore
import UniformTypeIdentifiers

// MARK: - Export a recorded GPS route through Shortcuts (#2679)
//
// Route export already ships as a share sheet on the workout detail screen (`WorkoutDetailView`'s
// "GPX - Strava, Garmin, most apps"), and the same file is what Strava, Garmin Connect and the rest
// read back as a timed activity. What it could not do was run unattended: every workout needed the
// sheet opened by hand.
//
// This exposes the SAME renderer to Shortcuts, so an automation can take the file and hand it to
// whichever app the wearer already uses. NOOP gains no account, no credential and no network call:
// the file leaves only when the wearer's own automation moves it, exactly like the share sheet.
// Issue #2679 records why a direct Strava API client is a separate scope decision rather than this.
//
// It reads `RouteStore` (the UserDefaults side-store, since `WorkoutRow` has no route column on
// Apple) rather than the database, so it needs no store handle and cannot contend with a running
// sync. An App Intent declared in the app target runs in NOOP's own process, so the plain
// `UserDefaults` suite `RouteStore` writes is readable here.

/// Why an export can fail. Only one case: a route either carries the per-point measurements an
/// honest export needs, or it does not. Conforms to `CustomLocalizedStringResourceConvertible` so
/// Shortcuts shows the reason instead of a generic failure.
enum RouteExportIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noExportableRoute

    var localizedStringResource: LocalizedStringResource {
        "NOOP has no recorded route with GPS measurements to export yet."
    }
}

/// The file format a route export produces. Mirrors `RouteExporter.Format` as a Shortcuts-visible
/// enum; kept separate because `AppEnum` conformance belongs to the iOS layer, not the pure package.
/// `CaseIterable` is spelled out rather than left to `AppEnum`'s refinement, so `allCases` is
/// synthesised explicitly instead of depending on conformance inference.
enum RouteExportFormatChoice: String, AppEnum, CaseIterable {
    case gpx
    case fit

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Route Format")

    // FIT carries what GPX has no element for: the heart-rate curve and the session summary, read from the
    // workout the route belongs to. See `perform`.
    static let caseDisplayRepresentations: [RouteExportFormatChoice: DisplayRepresentation] = [
        .gpx: DisplayRepresentation(title: "GPX"),
        .fit: DisplayRepresentation(title: "FIT", subtitle: "Route with heart rate and the workout summary"),
    ]

    var exporterFormat: RouteExporter.Format { self == .gpx ? .gpx : .fit }
}

/// Return the most recently recorded GPS route as a GPX or FIT file.
///
/// Only a route carrying trustworthy per-point measurements is exported. `WorkoutRoute`'s own
/// `hasExportableMeasurements` is the gate, and its contract is explicit that a legacy route without
/// point metadata "remain[s] drawable from [its] polyline but must never be exported with guessed
/// values" — so a route saved before that field existed is reported as unavailable rather than
/// shipped with an invented timeline.
struct ExportWorkoutRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Workout Route"
    static let description = IntentDescription(
        "Get the most recent recorded GPS route as a GPX or FIT file, ready to hand to Strava, Garmin Connect, or any other app.")
    /// No app UI is needed: the file is built from the on-device side-store and returned.
    static let openAppWhenRun = false

    @Parameter(title: "Format", default: .gpx)
    var format: RouteExportFormatChoice

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        guard let newest = Self.newestExportableRoute() else {
            // A real thrown error, not a parameter-resolution prompt: the format is already valid, it
            // is the data that is missing, and Shortcuts should surface that as a failed step rather
            // than asking the wearer to pick GPX again.
            throw RouteExportIntentError.noExportableRoute
        }
        // The file comes from `WorkoutFileExport`, the builder the workout's own share buttons use, so a
        // Shortcuts export and a share-sheet export of one workout carry the same data: heart rate,
        // calories and pauses are read from the database where they live, never from a copy kept beside
        // the route. Only when the workout row cannot be found (deleted, or the app's model not up within
        // a few seconds of a cold launch) does the route go out on its own, with its measured times and
        // heights.
        if let repo = await Self.repository(),
           let row = await Self.row(startTs: newest.startTs, sport: newest.sport, repo: repo),
           let file = await WorkoutFileExport.build(format.exporterFormat, row: row, repo: repo) {
            return .result(value: IntentFile(data: file.data, filename: file.name, type: .data),
                           dialog: "Exported your most recent route.")
        }
        let data = RouteExporter.render(
            format.exporterFormat,
            route: newest.points.map { RoutePoint(lat: $0.lat, lon: $0.lon) },
            startTs: newest.startTs,
            endTs: newest.endTs,
            sport: newest.sport,
            distanceM: newest.distanceM,
            recordedTimes: newest.points.map { Int($0.tMs / 1_000) },
            elevations: newest.points.map(\.altitudeM))
        // Named by the workout's start, matching the share sheet's `noop-route-<startTs>.<ext>` so the
        // same session exports to the same filename whichever path produced it.
        let name = "noop-route-\(newest.startTs).\(format.rawValue)"
        // `.data` rather than a guessed media type: GPX and FIT have no system `UTType`, and the
        // receiving app keys off the extension. Declaring something more specific would be asserting
        // a type the system does not actually know.
        return .result(value: IntentFile(data: data, filename: name, type: .data),
                       dialog: "Exported your most recent route.")
    }

    /// The running app's repository. A cold launch can hand the intent its first tick before the model
    /// exists, so it waits a few seconds for it, as the strap-sync shortcut does.
    @MainActor
    static func repository(waitSeconds: Int = 5) async -> Repository? {
        for _ in 0..<waitSeconds {
            if let model = AppModel.shared { return model.repo }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return AppModel.shared?.repo
    }

    /// The workout row a stored route belongs to, by the route's natural key.
    static func row(startTs: Int, sport: String, repo: Repository) async -> WorkoutRow? {
        let days = max(1, (Int(Date().timeIntervalSince1970) - startTs) / 86_400 + 2)
        return await repo.workoutRows(days: days).first { $0.startTs == startTs && $0.sport == sport }
    }

    /// One exportable route, resolved from the side-store without touching the database.
    struct Resolved {
        let startTs: Int
        let endTs: Int
        let sport: String
        let distanceM: Double
        let points: [WorkoutRoutePoint]
    }

    /// The newest route that carries exportable measurements, or nil when none does.
    ///
    /// `RouteStore`'s keys are "<startTs>|<sport>", so the greatest leading `startTs` is the most
    /// recent session without reading a workout row. `endTs` comes from the last point's own `tMs`
    /// rather than being assumed, which is why only routes with point metadata qualify.
    static func newestExportableRoute(from map: [String: WorkoutRoute]? = nil) -> Resolved? {
        let routes = map ?? RouteStore.loadMap()
        var best: Resolved?
        for (key, route) in routes where route.hasExportableMeasurements {
            guard let points = route.points, let last = points.last,
                  let parsed = Self.parseKey(key) else { continue }
            let endTs = Int(last.tMs / 1_000)
            guard endTs > parsed.startTs else { continue }
            let candidate = Resolved(startTs: parsed.startTs, endTs: endTs, sport: parsed.sport,
                                     distanceM: route.distanceM, points: points)
            if best == nil || candidate.startTs > best!.startTs { best = candidate }
        }
        return best
    }

    /// Split a `RouteStore` key back into its parts. A sport may itself contain "|" in principle, so
    /// the split is bounded to the FIRST separator and the remainder is the sport, matching how
    /// `RouteStore.key(startTs:sport:)` composes it.
    static func parseKey(_ key: String) -> (startTs: Int, sport: String)? {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let startTs = Int(parts[0]), !parts[1].isEmpty else { return nil }
        return (startTs, String(parts[1]))
    }
}
#endif
