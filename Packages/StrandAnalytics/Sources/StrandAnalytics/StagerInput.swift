import Foundation
import WhoopProtocol

// Adopted from ayiskakov/noop (`StagerInput`) by @ayiskakov: the stream plumbing the trained stager stages behind.

/// The stream plumbing the trained stager (`SleepStagerTrained`) stages behind: stable timestamp
/// order, a half-open clip to the rows a recipe reads, the memo key over those rows, and the tiling of a
/// per-epoch labelling into segments. Only the trained stager uses it; the shipped V2 keeps its own plumbing.
enum StagerInput {

    /// `xs` in stable timestamp order: same-second rows keep their input order, which decides how same-second
    /// beats pair up downstream. Returned as is, with no copy, when already in order (the common case).
    static func sortedByTs<T>(_ xs: [T], _ ts: (T) -> Int) -> [T] {
        var sorted = true
        for i in xs.indices.dropFirst() where ts(xs[i - 1]) > ts(xs[i]) { sorted = false; break }
        if sorted { return xs }
        return xs.enumerated().sorted { a, b in
            let ta = ts(a.element), tb = ts(b.element)
            return ta == tb ? a.offset < b.offset : ta < tb
        }.map { $0.element }
    }

    /// The rows of a ts-sorted stream inside `[lo, hi)`: a lower/upper-bound pair, then one copy of the kept
    /// rows, or none when nothing falls outside. The callers pass multi-day streams to every per-night call.
    static func clip<T>(_ xs: [T], lo: Int, hi: Int, ts: (T) -> Int) -> [T] {
        if xs.isEmpty { return xs }
        if ts(xs[0]) >= lo && ts(xs[xs.count - 1]) < hi { return xs }
        var a = 0, b = xs.count
        while a < b { let m = (a + b) / 2; if ts(xs[m]) < lo { a = m + 1 } else { b = m } }
        let start = a
        b = xs.count
        while a < b { let m = (a + b) / 2; if ts(xs[m]) < hi { a = m + 1 } else { b = m } }
        return Array(xs[start..<a])
    }

    /// Memo key for one staging call: the staged span, a fingerprint of each stream the recipes read (taken
    /// after the clip, so rows outside the read window cannot re-key it), and the sleep window, which changes
    /// the labels without changing any stream. Neither recipe reads `resp`, so it stays out.
    struct Key: Hashable {
        let start: Int; let end: Int
        let grav: StreamFingerprint; let hr: StreamFingerprint; let rr: StreamFingerprint
        let windowFrom: Int?; let windowTo: Int?

        init(start: Int, end: Int, grav: [GravitySample], hr: [HRSample], rr: [RRInterval],
             sleepWindow: (from: Int, to: Int)?) {
            self.start = start
            self.end = end
            self.grav = StreamFingerprint.of(grav, ts: { $0.ts }, quant: {
                StreamFingerprint.gravityQuant(x: $0.x, y: $0.y, z: $0.z)
            })
            self.hr = StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) })
            self.rr = StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) })
            windowFrom = sleepWindow?.from
            windowTo = sleepWindow?.to
        }
    }

    /// Tile `[start, end]` with one segment per epoch, merging runs of one label. The first segment back-fills
    /// `[start, first epoch)` and the last runs to `end`; an interior coverage gap is carried by the label
    /// before it.
    static func tile(epochStarts: [Int], labels: [String], start: Int, end: Int) -> [StageSegment] {
        var segments: [StageSegment] = []
        for (i, e) in epochStarts.enumerated() {
            let segStart = i == 0 ? start : e
            let segEnd = i == epochStarts.count - 1 ? end : epochStarts[i + 1]
            if let last = segments.last, last.stage == labels[i] {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: labels[i]))
            }
        }
        return segments
    }
}
