import Foundation
import CoreBluetooth

/// Durable append-only log of WHOOP 5.0/MG EVENT (type 48 / 0x30) frames, for deep-data protocol
/// research (#103).
///
/// EVENT frames are the strap's rare, still mostly uncatalogued records — e.g. the bi-hourly 56-byte
/// record that tracks the nightly sleep-SpO₂ measurement cycle. Decoding them needs many
/// (raw bytes, ground-truth value) pairs collected across weeks, which the session-scoped
/// `PuffinFrameRecorder` cannot provide: its bulk capture files churn under a directory cap, so
/// rare frames age out. This log keeps ONLY the ~150 tiny EVENT frames a day, in its own file that
/// the bulk-capture eviction never touches, so they survive long enough to correlate.
///
/// Gated on the same Settings toggle as the frame recorder (`PuffinFrameRecorder.enabledKey`) —
/// capture is passive/read-only with respect to the strap, and this adds no new setting. One JSONL
/// line per frame (`{"ts_ms":…,"char":…,"hex":"…"}` — the same key names as `PuffinCaptureRecord`,
/// so existing tooling reads it). Rotates at a soft cap keeping one previous generation, the same
/// idiom as the Android twin (`WhoopBleClient.writeWhoop5EventLog`, `whoop5-events.jsonl`).
@MainActor
final class PuffinEventLog {

    /// Rotate when the live file exceeds this. EVENT frames are ~40–120 B of hex each; a few KB per
    /// day of wear, so 5 MB is years of history.
    private static let softCapBytes = 5 * 1024 * 1024

    /// The WHOOP 5 inner-record type byte for EVENT frames (the inner record starts at offset 8).
    private static let eventTypeByte: UInt8 = 0x30

    private var handle: FileHandle?
    private var disabled = false

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PuffinFrameRecorder.enabledKey)
    }

    /// `<AppSupport>/OpenWhoop/puffin-events.jsonl` — deliberately OUTSIDE `puffin-captures/`, whose
    /// soft-cap eviction deletes oldest files wholesale.
    private static func logURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("puffin-events.jsonl")
    }

    /// Append `frame` if it is a WHOOP 5 EVENT frame and capture is enabled. Cheap for every other
    /// frame: a single byte compare, no parse. Call for BOTH live and offload frames — the strap
    /// replays historical EVENTs during a sync, and either path may be the only one that sees a
    /// given record (the official app's trim can empty the strap's history before NOOP syncs).
    func appendIfEvent(frame: [UInt8], char: CBUUID) {
        guard !disabled, frame.count > 8, frame[8] == Self.eventTypeByte, isEnabled else { return }
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        let line = "{\"ts_ms\":\(tsMs),\"char\":\"\(char.uuidString.lowercased())\",\"hex\":\"\(hex)\"}\n"
        do {
            let h = try openHandle()
            try h.write(contentsOf: Data(line.utf8))
        } catch {
            // A diagnostics log must never affect the connection path: disable for this launch.
            disabled = true
        }
    }

    /// Close the handle (e.g. on disconnect) so the file is safe to share/export immediately.
    func close() {
        try? handle?.close()
        handle = nil
    }

    private func openHandle() throws -> FileHandle {
        if let handle = handle { return handle }
        let url = try Self.logURL()
        let fm = FileManager.default
        // Rotate at the cap: keep one previous generation, then start fresh (Android twin's idiom).
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.softCapBytes {
            let old = url.deletingPathExtension().appendingPathExtension("jsonl.1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        return h
    }
}
