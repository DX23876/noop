import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura 0x47 motion_events stream — a Tier-A RESEARCH corpus for
/// calibration, NOT a datastore row (see `OuraMotionDumpLine` for the rationale). Direct twin of
/// `OuraActivityDump`: owns the file handle, the on-disk path, the once-per-launch "here is the file" log
/// line, and a persistent ring-time high-water so records the ring re-serves across reconnects are written
/// exactly once instead of duplicating the corpus.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-motion-<deviceId>.jsonl` — beside the app's
/// SQLite so the user can find it. Purely diagnostic and safe to delete; nothing reads it back. It exists
/// so the averaged accel vector can be calibrated offline (resting magnitude → g scale, cadence during
/// stillness) before the mapping wires it into `gravitySample` (issue #804).
final class OuraMotionDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let highWaterKey: String
    /// Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
    /// Persisted in UserDefaults so the dedup survives app relaunches (a fresh drain re-emits old records).
    private var highWater: UInt32
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false

    /// Rotate the sidecar past this size (keeping one previous ".1"), so an always-on research corpus is
    /// bounded to ~2× this on disk instead of growing forever. Matches `OuraActivityDump`.
    private static let maxBytes = 25 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
        self.highWaterKey = "oura.motionDump.highwater.\(deviceId)"
        let stored = UserDefaults.standard.integer(forKey: highWaterKey)   // 0 when unset → writes everything
        self.highWater = stored > 0 ? UInt32(truncatingIfNeeded: stored) : 0
    }

    /// Append one anchored motion record. No-op when `ringTs` is not above the high-water (a re-serve), so
    /// the corpus stays deduped. Best-effort: any file error is logged once and never disrupts the BLE path.
    /// Call ONLY with an anchored `utc` (an un-anchored record has no real time axis and re-arrives anchored
    /// on the next drain).
    func record(ringTs: UInt32, utc: Int, orientation: Int, motionSeconds: Int, x: Int, y: Int, z: Int,
                lowIntensity: Int?, highIntensity: Int?) {
        guard ringTs > highWater else { return }
        guard var url = resolveURL() else { return }
        // Bound the corpus (rotate to a single ".1", dropping the prior one) so an always-on research sidecar
        // can't grow unbounded — same rotation as OuraActivityDump. Read the size via a fresh FileManager stat
        // rather than URL.resourceValues, whose cache on the reused URL can return a stale small size.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            fileURL = nil
            guard let fresh = resolveURL() else { return }
            url = fresh
        }

        let line = OuraMotionDumpLine.encode(
            deviceId: deviceId, ringTs: ringTs, utc: utc,
            iso: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))),
            orientation: orientation, motionSeconds: motionSeconds, x: x, y: y, z: z,
            lowIntensity: lowIntensity, highIntensity: highIntensity)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: motion dump write failed - \(error.localizedDescription)")
            return
        }

        highWater = ringTs
        UserDefaults.standard.set(Int(ringTs), forKey: highWaterKey)
        if !announced {
            announced = true
            log("Oura: motion 0x47 dump → \(url.path) [Tier-A calibration corpus, JSONL, deduped by ring-time]")
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
            let url = dir.appendingPathComponent("oura-motion-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: motion dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
