import Foundation

/// Append-only record of the route of the workout in progress.
///
/// The route used to live only in memory, so when iOS ended a backgrounded app mid-walk the session was
/// restored but its route started again from nothing — distance and pace for everything before were gone.
/// Points are appended here in small batches and read back when the session is restored. One line per
/// point (`lat,lon`), so an interrupted write can at most lose its last, partial line.
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
        guard !points.isEmpty else { return }
        let text = points.map { String(format: "%.7f,%.7f\n", $0.lat, $0.lon) }.joined()
        guard let data = text.data(using: .utf8) else { return }
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
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ",")
            guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return RouteMath.LatLng(lat, lon)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
