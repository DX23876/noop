import Foundation
import CoreBluetooth

/// Durable append-only log of WHOOP 5.0/MG **high-rate deep buffers** — the large type-0x2F (R22)
/// packets that carry tens-of-Hz sensor data (motion + optical) rather than the 1 Hz historical
/// rollup NOOP already decodes (#423).
///
/// On-strap probing (#423) established that the 5/MG has no live raw-IMU stream, but it DOES bank
/// high-rate motion (accel content verified: int16-ish triples sphere-fitting to ~1 g at the 1/4096
/// scale) and ships it inside big type-0x2F buffers during the connect-time offload burst — 124 B
/// (≈1 Hz record), 1244 B and 2140 B (≈32 and ≈59 sub-records per timestamped second). NOOP's
/// historical decoder pulls the 1 Hz gravity vector out and DISCARDS the high-rate remainder. Those
/// bursts are ephemeral and backlog-gated, so a byte-perfect decoder can't be captured on demand — it
/// needs many (raw buffer, wall-clock) pairs accumulated across days of ordinary wear + labeled
/// activity. This log keeps ONLY the big (≥`minBufferBytes`) type-0x2F buffers, in its own file that
/// the bulk `PuffinFrameRecorder` eviction never touches, so they survive long enough to reverse.
///
/// Gated on the same Settings toggle as the frame recorder (`PuffinFrameRecorder.enabledKey`) —
/// capture is passive/read-only with respect to the strap and adds no new setting. One JSONL line per
/// buffer (`{"ts_ms":…,"strap_ts":…,"size":…,"offload":…,"char":…,"hex":"…"}`); `strap_ts` is the
/// unix second the strap stamped at payload offset 15 (frame byte 15), the load-bearing key for
/// aligning a buffer with what the wearer was doing. Rotates at a soft cap keeping one previous
/// generation, the same idiom as `PuffinEventLog`. Swift-only for now (experimental #423 instrument);
/// a Kotlin twin follows if this graduates past reverse-engineering.
@MainActor
final class PuffinDeepBufferLog {

    /// The 2140-B buffers are ~4.3 KB of hex each and arrive in bursts, so a bigger cap than the
    /// EVENT log: 60 MB live keeps roughly a few hours of accumulated high-rate bursts, ample to
    /// reverse the layout, and rotation bounds total disk at ~120 MB.
    private static let softCapBytes = 60 * 1024 * 1024

    /// WHOOP 5/MG inner-record type byte for the R22 deep packets (type 47 / 0x2F), at offset 8 (the
    /// same position `BLEManager.isOffloadFrame` / `PuffinEventLog` index). The 1 Hz historical rollup
    /// is also type-0x2F but small; `minBufferBytes` keeps only the high-rate buffers.
    private static let deepTypeByte: UInt8 = 0x2F
    private static let innerRecordOffset = 8
    /// Skip the ~124-B ≈1 Hz record; keep the 1244-/2140-B high-rate buffers.
    private static let minBufferBytes = 1000

    /// Pure predicate: is `frame` a WHOOP 5/MG high-rate deep buffer? A reassembled frame's inner-record
    /// type byte sits at offset 8, so this needs `count > 8` before indexing. Extracted so the offset-8
    /// magic number is unit-testable without a strap.
    nonisolated static func isDeepBuffer(_ frame: [UInt8]) -> Bool {
        frame.count > innerRecordOffset
            && frame.count >= minBufferBytes
            && frame[innerRecordOffset] == deepTypeByte
    }

    private var handle: FileHandle?
    private var disabled = false

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PuffinFrameRecorder.enabledKey)
    }

    /// `<AppSupport>/OpenWhoop/puffin-deepbuffers.jsonl` — OUTSIDE `puffin-captures/`, whose soft-cap
    /// eviction deletes oldest files wholesale.
    private static func logURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("puffin-deepbuffers.jsonl")
    }

    /// The strap's own unix-second stamp at frame offset 15 (u32 LE), or nil if the frame is too short.
    /// This is the timestamp the high-rate records inside the buffer are relative to.
    private static func strapTs(_ frame: [UInt8]) -> UInt32? {
        guard frame.count > 18 else { return nil }
        return UInt32(frame[15]) | (UInt32(frame[16]) << 8) | (UInt32(frame[17]) << 16) | (UInt32(frame[18]) << 24)
    }

    /// Append `frame` if it is a WHOOP 5 high-rate deep buffer and capture is enabled. Cheap for every
    /// other frame: a length + single-byte compare, no parse, BEFORE the `isEnabled` read. Call for both
    /// live and offload frames (`isOffload` recorded so the reverse pass can separate a real-time buffer
    /// from a replayed historical one).
    func appendIfDeepBuffer(frame: [UInt8], char: CBUUID, isOffload: Bool) {
        guard !disabled, Self.isDeepBuffer(frame), isEnabled else { return }
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        let strapTs = Self.strapTs(frame).map { String($0) } ?? "null"
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        let line = "{\"ts_ms\":\(tsMs),\"strap_ts\":\(strapTs),\"size\":\(frame.count),"
            + "\"offload\":\(isOffload),\"char\":\"\(char.uuidString.lowercased())\",\"hex\":\"\(hex)\"}\n"
        do {
            var h = try openHandle()
            if try h.offset() > UInt64(Self.softCapBytes) {
                close()
                h = try openHandle()
            }
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
