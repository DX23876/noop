import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura 0x50 activity/MET stream — a Tier-B RESEARCH corpus, never a
/// datastore row (see `OuraActivityDumpLine` for the honest-data rationale). Owns the file handle, the
/// on-disk path, the once-per-launch "here is the file" log line, and a persistent ring-time high-water so
/// the records the ring re-serves across reconnects (observed heavily under connection churn) are written
/// exactly once instead of duplicating the corpus.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-activity-<deviceId>.jsonl` — beside the app's
/// SQLite so the user can find it. Purely diagnostic and safe to delete; nothing reads it back.
final class OuraActivityDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let highWaterKey: String
    /// Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
    /// Persisted in UserDefaults so the dedup survives app relaunches (a fresh drain re-emits old records).
    private var highWater: UInt32
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
        self.highWaterKey = "oura.activityDump.highwater.\(deviceId)"
        let stored = UserDefaults.standard.integer(forKey: highWaterKey)   // 0 when unset → writes everything
        self.highWater = stored > 0 ? UInt32(truncatingIfNeeded: stored) : 0
    }

    /// Append one anchored activity record. No-op when `ringTs` is not above the high-water (a re-serve),
    /// so the corpus stays deduped. Best-effort: any file error is logged once and never disrupts the BLE
    /// path. Call ONLY with an anchored `utc` (an un-anchored record has no real time axis and re-arrives
    /// anchored on the next drain).
    func record(ringTs: UInt32, utc: Int, state: Int, secPerSample: Int, met: [Double]) {
        guard ringTs > highWater else { return }
        guard let url = resolveURL() else { return }

        let line = OuraActivityDumpLine.encode(
            deviceId: deviceId, ringTs: ringTs, utc: utc,
            iso: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))),
            state: state, secPerSample: secPerSample, met: met)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: activity MET dump write failed - \(error.localizedDescription)")
            return
        }

        highWater = ringTs
        UserDefaults.standard.set(Int(ringTs), forKey: highWaterKey)
        if !announced {
            announced = true
            log("Oura: activity MET dump → \(url.path) [Tier-B research corpus, JSONL, deduped by ring-time]")
        }
    }

    /// Resolve (and create on first use) the sidecar file + its parent directory. Cached; a failure is
    /// logged once and latched so we never spam the strap log on a read-only volume.
    private func resolveURL() -> URL? {
        if let fileURL { return fileURL }
        if resolveFailed { return nil }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("OpenWhoop/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeId = deviceId.replacingOccurrences(of: "/", with: "_")
            let url = dir.appendingPathComponent("oura-activity-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: activity MET dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
