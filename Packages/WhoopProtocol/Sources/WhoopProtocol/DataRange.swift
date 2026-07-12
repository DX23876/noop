import Foundation

/// GET_DATA_RANGE frame parsing. Pure + byte-identical to the Kotlin twin `com.noop.protocol.DataRange`.
///
/// Extracted from `BLEManager`/`WhoopBleClient` (#286 follow-up): the newest-record read gates automatic
/// sync (`isFutureDatedNewest` → `BackfillPolicy`), so its value must stay byte-identical across platforms.
/// Living here means both a WhoopProtocol `swift test` and the Kotlin JVM test pin the parity — the app-target
/// copies were previously testable on the Kotlin side only.
public enum DataRange {
    /// The newest plausible unix time banked by the strap, from a GET_DATA_RANGE frame.
    ///
    /// Scans EVERY byte offset — the newest-record `u32` isn't on a fixed grid (it sits at byte offset 8 on
    /// WHOOP 4.0, off the old aligned-from-7 scan, which straddled it and returned nil). Keeps the newest
    /// word inside a plausible unix window (2023-11…2030-03), preferring the newest that is NOT implausibly
    /// future (> `wallNowUnix + futureSkewSeconds`) so a garbage future word can't latch and stall auto-sync
    /// (#451/#928/#1012). Falls back to the newest-any word so a genuinely future-dated RTC is still surfaced
    /// downstream and the future-date guard still fires. Returns nil only for a too-short frame or no
    /// plausible word at all.
    public static func newestUnix(from frame: [UInt8], wallNowUnix: Int, futureSkewSeconds: Int) -> Int? {
        guard frame.count >= 4 else { return nil }
        let futureCutoff = wallNowUnix + futureSkewSeconds
        var newestNotFuture: Int? = nil
        var newestAny: Int? = nil
        var i = 0
        while i + 4 <= frame.count {
            let w = Int(frame[i]) | Int(frame[i + 1]) << 8 | Int(frame[i + 2]) << 16 | Int(frame[i + 3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 {
                newestAny = max(newestAny ?? 0, w)
                if w <= futureCutoff { newestNotFuture = max(newestNotFuture ?? 0, w) }
            }
            i += 1
        }
        return newestNotFuture ?? newestAny
    }

    /// The OLDEST plausible unix time banked by the strap (start of stored history), from a GET_DATA_RANGE
    /// frame — the low end of the banked span (oldest…newest = the backlog DEPTH a deep oldest-first drain
    /// must cover before recent nights land, #364).
    ///
    /// Unlike `newestUnix`, this scans ONLY the 4-byte grid aligned from offset 7, NOT every offset — and
    /// that asymmetry is DELIBERATE. The minimum is fragile in a way the maximum is not: an any-offset scan
    /// of a real WHOOP 4.0 frame surfaces a spurious straddle word (offset 6 → 1_754_857_506, ~11 months
    /// *before* the true newest at offset 8) that would hijack the min and report a bogus deep backlog. The
    /// max is immune — the real newest dominates it — which is exactly why `newestUnix` can scan every offset.
    /// The aligned grid skips that straddle, so real frames with no distinct oldest word return nil here.
    /// Do NOT "make this consistent with `newestUnix`" by scanning every offset without anchoring — see
    /// `DataRangeTests.testOldestAlignedScanSkipsTheSpuriousOffset6Straddle`.
    public static func oldestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        var oldest: Int? = nil
        var i = 7
        while i + 4 <= frame.count {
            let w = Int(frame[i]) | Int(frame[i + 1]) << 8 | Int(frame[i + 2]) << 16 | Int(frame[i + 3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { oldest = min(oldest ?? .max, w) }
            i += 4
        }
        return oldest
    }
}
