import Foundation
import WhoopProtocol

/// Selects which delivery path of a WHOOP's R-R beats is scored, one fixed five-minute segment at a time.
///
/// A WHOOP reports the same heartbeat over up to three paths: its own history offload (stamped by the
/// strap's clock), the standard 0x2A37 Heart Rate profile (stamped on receipt by the phone) and the
/// proprietary realtime record. Scoring two of them together counts every beat twice. Rows stay in SQLite
/// for diagnostics and future reprocessing; only the scoring read chooses.
///
/// ## Why segments, and not single beats or whole hours
///
/// Matching one beat against the nearest beat of another path only works while both clocks agree to within
/// the match radius. They do not stay that way. On one WHOOP 5/MG's nights of 2026-09-09 to 09-26 the
/// standard-profile copy of a beat sat most often 1-2 s after its history copy at the start of that span,
/// 4 s on 09-25 and 5-6 s on 09-26, when 39,191 of 39,524 standard beats had their history twin more than
/// 3 s away. A per-beat radius survived that only because the history train is dense enough that SOME beat
/// always lies nearby, and the number of seams it spliced into the train rose from 12-48 a night to 146
/// and 233. Choosing a whole segment never splices two clocks inside it, so a drifting offset only matters
/// at the few boundaries where the chosen path changes.
///
/// Choosing a whole UTC hour (upstream #2478) has the opposite weakness, which that change records: an hour
/// holding a little history still prefers it over a complete live train. Here a path is only preferred
/// where it is nearly complete. In each segment every path's OCCUPIED SECONDS are counted (distinct
/// timestamps, so a path that repeats beats cannot inflate its claim), and the highest-ranked path holding
/// at least four fifths of the fullest path's seconds wins. The fraction decides which complete-enough
/// path is read; it never drops a beat by its value.
///
/// Path precedence is history > standard > realtime > no provenance, for every WHOOP. The history carries
/// the strap's own timestamps, where standard beats are stamped on receipt. A row's label (`srcChannel`)
/// names its path before its `transport` does, because a promotion relabels a row without rewriting its
/// transport; only the labels of the owner's own family count, so a stray tag cannot steer another
/// device's read. Rows with no provenance at all (written before either column existed) are a path of
/// their own.
///
/// A chosen path owns the stretch of its segment from its first beat to its last, widened by
/// `overlapRadiusSeconds`, and nothing is ever spliced into the middle of it. Two labelled paths never
/// share a segment: filling one's edges from the other would bring back, a few beats at a time, the
/// clock splice this exists to prevent (on the nights above it took the seams from 0-2 back to 43).
/// Beats WITHOUT provenance are the exception, in both directions: before or after the chosen stretch
/// they are read, and a labelled stretch beside a chosen unlabelled one is read too. So the first
/// labelled beats after an upgrade never blank the older beats that share their segment.
///
/// Inside the chosen path a labelled beat still replaces an unlabelled copy within `overlapRadiusSeconds`,
/// as before: both copies there were stamped by the same clock. Every decision is local to its segment, so
/// a five-minute read and a whole-night read choose the same beats as long as the caller reads whole
/// segments (`rrIntervals` does).
///
/// Oura and other sources carry no WHOOP provenance and pass through untouched.
enum RRTransportReconciler {
    static let overlapRadiusSeconds = 3

    /// Length of one selection segment, aligned to the Unix epoch.
    static let segmentSeconds = 300

    /// A path counts as complete enough when `occupied * adequacyDenominator >= fullest * adequacyNumerator`.
    static let adequacyNumerator = 4
    static let adequacyDenominator = 5

    /// The delivery path a beat arrived on. Raw values are the precedence, highest wins.
    enum Path: Int, Comparable, CaseIterable {
        case unknown = 0
        case realtime = 1
        case standard = 2
        case history = 3

        static func < (lhs: Path, rhs: Path) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The path a beat arrived on. `whoop5` names the owner's family, whose labels alone are read; nil
    /// reads both families' labels (diagnostics over rows already selected).
    static func path(_ row: RRInterval, whoop5: Bool? = nil) -> Path {
        switch (row.srcChannel, whoop5) {
        case (.whoop5Historical?, true?), (.whoop5Historical?, nil),
             (.whoop4Historical?, false?), (.whoop4Historical?, nil): return .history
        case (.whoop5Standard?, true?), (.whoop5Standard?, nil),
             (.whoop4Standard?, false?), (.whoop4Standard?, nil): return .standard
        case (.whoop5Realtime?, true?), (.whoop5Realtime?, nil),
             (.whoop4Realtime?, false?), (.whoop4Realtime?, nil): return .realtime
        default: break
        }
        switch row.transport {
        case .whoopHistorical?: return .history
        case .standardHeartRate?: return .standard
        case .whoopRealtime?: return .realtime
        case nil: return .unknown
        }
    }

    /// The segment a timestamp falls in (floor division, so it holds for any sign).
    static func segment(_ ts: Int) -> Int {
        ts >= 0 ? ts / segmentSeconds : -((-ts + segmentSeconds - 1) / segmentSeconds)
    }

    /// First second of the segment holding `ts`.
    static func segmentStart(_ ts: Int) -> Int { segment(ts) * segmentSeconds }

    /// Last second of the segment holding `ts`.
    static func segmentEnd(_ ts: Int) -> Int { segmentStart(ts) + segmentSeconds - 1 }

    static func reconcile(_ rows: [RRInterval], whoop5: Bool = false) -> [RRInterval] {
        let paths = rows.map { path($0, whoop5: whoop5) }
        guard paths.contains(where: { $0 != .unknown }) else { return rows }

        // Group row indices by segment, keeping each segment's rows in input order.
        var bySegment: [Int: [Int]] = [:]
        var segmentOrder: [Int] = []
        for (index, row) in rows.enumerated() {
            let seg = segment(row.ts)
            if bySegment[seg] == nil { segmentOrder.append(seg) }
            bySegment[seg, default: []].append(index)
        }
        var keep = [Bool](repeating: false, count: rows.count)
        for seg in segmentOrder {
            for index in selectedIndices(bySegment[seg] ?? [], rows: rows, paths: paths) { keep[index] = true }
        }
        var kept: [RRInterval] = []
        kept.reserveCapacity(rows.count)
        for (row, isKept) in zip(rows, keep) where isKept { kept.append(row) }
        return preferringLabels(kept, whoop5: whoop5)
    }

    /// The rows of one segment that are read: the complete-enough path of highest precedence over the
    /// stretch it covers, then the same choice again among the rows left before and after that stretch,
    /// where a labelled path may only be joined by rows without provenance.
    static func selectedIndices(_ indices: [Int], rows: [RRInterval], paths: [Path]) -> [Int] {
        var remaining = indices
        var selected: [Int] = []
        while let chosen = mostCompletePath(remaining, rows: rows, paths: paths) {
            var lo = Int.max, hi = Int.min
            for index in remaining where paths[index] == chosen {
                selected.append(index)
                lo = min(lo, rows[index].ts)
                hi = max(hi, rows[index].ts)
            }
            lo -= overlapRadiusSeconds
            hi += overlapRadiusSeconds
            remaining = remaining.filter {
                paths[$0] != chosen && (rows[$0].ts < lo || rows[$0].ts > hi)
                    && (chosen == .unknown || paths[$0] == .unknown)
            }
        }
        return selected
    }

    /// The highest-precedence path holding at least four fifths of the seconds the fullest path holds.
    /// Seconds, not rows: a path storing two beats in one second, or one beat twice, occupies it once.
    static func mostCompletePath(_ indices: [Int], rows: [RRInterval], paths: [Path]) -> Path? {
        guard !indices.isEmpty else { return nil }
        var seconds: [Path: Set<Int>] = [:]
        for index in indices { seconds[paths[index], default: []].insert(rows[index].ts) }
        let fullest = seconds.values.map(\.count).max() ?? 0
        return seconds
            .filter { $0.value.count * adequacyDenominator >= fullest * adequacyNumerator }
            .keys.max()
    }

    /// Within each segment, drop a beat when a higher-ranked observation lies within `overlapRadiusSeconds`.
    /// After path selection a segment holds ONE labelled path (its labelled and older unlabelled copies)
    /// plus, at most, rows without provenance outside that path's stretch, so this only ever replaces an
    /// older unlabelled row with its labelled twin.
    static func preferringLabels(_ rows: [RRInterval], whoop5: Bool) -> [RRInterval] {
        var out: [RRInterval] = []
        out.reserveCapacity(rows.count)
        var start = 0
        while start < rows.count {
            let seg = segment(rows[start].ts)
            var end = start + 1
            while end < rows.count, segment(rows[end].ts) == seg { end += 1 }
            appendPreferringLabels(rows[start..<end], whoop5: whoop5, to: &out)
            start = end
        }
        return out
    }

    private static func appendPreferringLabels(_ rows: ArraySlice<RRInterval>, whoop5: Bool,
                                               to out: inout [RRInterval]) {
        let ranks = rows.map { rank($0, whoop5: whoop5) }
        var timesByRank: [Int: [Int]] = [:]
        for (row, rowRank) in zip(rows, ranks) where rowRank > 0 {
            timesByRank[rowRank, default: []].append(row.ts)
        }
        // One rank present: nothing can cover anything. The common case, and it keeps the unit restore
        // the only work left.
        guard timesByRank.count > 1 || (timesByRank.count == 1 && ranks.contains(0)) else {
            for row in rows { out.append(whoop5 ? restoringWhoop5StandardUnits(row) : row) }
            return
        }
        for key in timesByRank.keys { timesByRank[key]?.sort() }
        let presentRanks = timesByRank.keys.sorted()
        for (row, rowRank) in zip(rows, ranks) {
            let covered = presentRanks.contains { higher in
                higher > rowRank && hasNearby(row.ts, in: timesByRank[higher] ?? [])
            }
            guard !covered else { continue }
            out.append(whoop5 ? restoringWhoop5StandardUnits(row) : row)
        }
    }

    /// Higher wins inside the overlap radius. Zero is "no provenance".
    static func rank(_ row: RRInterval, whoop5: Bool) -> Int {
        guard whoop5 else {
            if row.srcChannel == .whoop4Historical { return 4 }
            switch row.transport ?? impliedWhoop4Transport(row.srcChannel) {
            case .standardHeartRate: return 3
            case .whoopHistorical: return 2
            case .whoopRealtime: return 1
            case nil: return 0
            }
        }
        switch row.srcChannel {
        case .whoop5Historical: return 7
        case .whoop5Standard: return 5
        case .whoop5Realtime: return 4
        default: break
        }
        switch row.transport {
        case .whoopHistorical: return 6
        case .whoopRealtime: return 3
        case .standardHeartRate: return 2
        case nil: return 0
        }
    }

    /// The WHOOP 4 live labels (9 type-40 realtime, 10 standard 0x2A37) name the same delivery paths as
    /// `transport`. The app writes both, so this only decides a row that carries the label alone.
    static func impliedWhoop4Transport(_ channel: RRSourceChannel?) -> RRTransport? {
        switch channel {
        case .whoop4Realtime: return .whoopRealtime
        case .whoop4Standard: return .standardHeartRate
        default: return nil
        }
    }

    /// A WHOOP 5 standard-profile beat stored before #2195 went through `round(raw * 1000 / 1024)`, but the
    /// strap sends milliseconds there. Only an unlabelled standard row can be one: since #2195 the app
    /// reads raw milliseconds exactly when it labels the row 7 (`BLEManager.parseStandardHR`). The inverse
    /// is within 1 ms of the value the strap sent.
    static func restoringWhoop5StandardUnits(_ row: RRInterval) -> RRInterval {
        guard row.transport == .standardHeartRate, row.srcChannel == nil else { return row }
        return RRInterval(ts: row.ts, rrMs: legacyStandardMilliseconds(row.rrMs),
                          srcChannel: row.srcChannel, transport: row.transport,
                          ord: row.ord, seq: row.seq)
    }

    static func legacyStandardMilliseconds(_ stored: Int) -> Int {
        Int((Double(stored) * 1024.0 / 1000.0).rounded())
    }

    private static func hasNearby(_ ts: Int, in sortedTimes: [Int]) -> Bool {
        guard !sortedTimes.isEmpty else { return false }
        var low = 0
        var high = sortedTimes.count
        while low < high {
            let mid = low + (high - low) / 2
            if sortedTimes[mid] < ts { low = mid + 1 } else { high = mid }
        }
        if low < sortedTimes.count, abs(sortedTimes[low] - ts) <= overlapRadiusSeconds { return true }
        if low > 0, abs(sortedTimes[low - 1] - ts) <= overlapRadiusSeconds { return true }
        return false
    }
}

/// Strap-log readouts of the delivery-path choice made by `RRTransportReconciler` (#1118).
public enum RRDeliveryPaths {
    /// How many five-minute segments of `rows` read each path (a segment filled from two paths counts for
    /// both), and how many seams the scored train carries: consecutive beats from different paths. `rows`
    /// are what `rrIntervals` returned.
    public static func segmentCensus(_ rows: [RRInterval]) -> String {
        var segmentsByPath: [RRTransportReconciler.Path: Set<Int>] = [:]
        var seams = 0
        var lastPath: RRTransportReconciler.Path?
        for row in rows {
            let rowPath = RRTransportReconciler.path(row)
            segmentsByPath[rowPath, default: []].insert(RRTransportReconciler.segment(row.ts))
            if let previous = lastPath, previous != rowPath { seams += 1 }
            lastPath = rowPath
        }
        func count(_ p: RRTransportReconciler.Path) -> Int { segmentsByPath[p]?.count ?? 0 }
        return "hist=\(count(.history)) std=\(count(.standard)) rt=\(count(.realtime)) "
            + "unk=\(count(.unknown)) seams=\(seams)"
    }

    /// Where the history copy of a standard-profile beat sits, from rows AS STORED (`rawRrIntervals`).
    ///
    /// Each standard beat is matched against history beats of the same value (±1 ms, after the WHOOP 5
    /// unit restore) up to `window` seconds either side, and every matching offset is counted. The two
    /// most frequent offsets are reported as `standard ts - history ts`, beside how many standard beats
    /// found a twin there. This measures the clock offset that decides whether a per-beat match could
    /// pair the copies. A coincidental equal value elsewhere adds to the count, which is why it reports
    /// the distribution's peak rather than a mean. nil when either path is absent.
    public static func standardMinusHistoryOffset(_ rows: [RRInterval], whoop5: Bool,
                                                  window: Int = 10) -> String? {
        var history: [Int: [Int]] = [:]
        var standard: [RRInterval] = []
        for row in rows {
            switch RRTransportReconciler.path(row) {
            case .history: history[row.ts, default: []].append(row.rrMs)
            case .standard:
                standard.append(whoop5 ? RRTransportReconciler.restoringWhoop5StandardUnits(row) : row)
            default: break
            }
        }
        guard !history.isEmpty, !standard.isEmpty else { return nil }
        var matched: [Int: Int] = [:]
        for beat in standard {
            for offset in -window...window {
                guard let values = history[beat.ts - offset],
                      values.contains(where: { abs($0 - beat.rrMs) <= 1 }) else { continue }
                matched[offset, default: 0] += 1
            }
        }
        let ranked = matched.sorted { ($0.value, -abs($0.key)) > ($1.value, -abs($1.key)) }
        guard let top = ranked.first else { return "none/\(standard.count) window=±\(window)s" }
        func signed(_ s: Int) -> String { s > 0 ? "+\(s)s" : "\(s)s" }
        var line = "\(signed(top.key)):\(top.value)/\(standard.count)"
        if ranked.count > 1 { line += " next=\(signed(ranked[1].key)):\(ranked[1].value)" }
        return line + " window=±\(window)s"
    }
}
