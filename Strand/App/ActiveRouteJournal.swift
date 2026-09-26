import Foundation

/// Append-only record of the route of the workout in progress.
///
/// The route used to live only in memory, so when iOS ended a backgrounded app mid-walk the session was
/// restored but its route started again from nothing — distance and pace for everything before were gone.
/// Points are appended here in small batches and read back when the session is restored. One line per
/// point, so an interrupted write can at most lose its last, partial line. A line is `lat,lon`, or
/// `lat,lon,accuracyM,tMs` when it carries the fix's own measurement (#2340), which the Health route
/// export needs; a journal holding any bare line restores a drawable route that is not exported.
///
/// Lives in Application Support, excluded from backup, and is deleted when the workout ends or is
/// discarded. It is never a second copy of a finished route; `RouteStore` keeps those.
struct ActiveRouteJournal {
    let url: URL

    init(url: URL = ActiveRouteJournal.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ActiveSession", isDirectory: true)
            .appendingPathComponent("route.txt")
    }

    func append(_ points: [RouteMath.LatLng]) {
        write(points.map { String(format: "%.7f,%.7f\n", $0.lat, $0.lon) }.joined())
    }

    /// Appends points together with their recorded accuracy and time.
    func append(measured points: [WorkoutRoutePoint]) {
        write(points.map {
            String(format: "%.7f,%.7f,%.2f,%lld\n", $0.lat, $0.lon, $0.accuracyM, $0.tMs)
        }.joined())
    }

    private func write(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var created = url
            fm.createFile(atPath: url.path, contents: data)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? created.setResourceValues(values)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Every complete, in-range point written so far. Malformed or partial lines are skipped.
    func load() -> [RouteMath.LatLng] {
        loadMeasured().track
    }

    /// The restored track, plus its per-point measurements when EVERY restored point carries one. A single
    /// bare `lat,lon` line (a journal written before measurements, or a mixed one) makes `points` nil, so a
    /// route is never exported with measurements that describe only part of it.
    func loadMeasured() -> (track: [RouteMath.LatLng], points: [WorkoutRoutePoint]?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], nil) }
        var track: [RouteMath.LatLng] = []
        var points: [WorkoutRoutePoint] = []
        var allMeasured = true
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ",")
            guard parts.count == 2 || parts.count == 4, let lat = Double(parts[0]), let lon = Double(parts[1]),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { continue }
            track.append(RouteMath.LatLng(lat, lon))
            if parts.count == 4, let accuracy = Double(parts[2]), let tMs = Int64(parts[3]) {
                points.append(WorkoutRoutePoint(lat: lat, lon: lon, accuracyM: accuracy, tMs: tMs))
            } else {
                allMeasured = false
            }
        }
        return (track, allMeasured && !track.isEmpty ? points : nil)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
