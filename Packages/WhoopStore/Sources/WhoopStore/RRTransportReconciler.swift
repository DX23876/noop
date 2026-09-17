import Foundation
import WhoopProtocol

/// Selects one R-R observation per heartbeat when several delivery paths recorded it.
///
/// Rows stay in SQLite for diagnostics and future reprocessing. A row is dropped from a READ only when an
/// observation of higher precedence lies within `overlapRadiusSeconds` of it, so a labelled stream replaces
/// older rows only where it actually covers them: a partial offload, or the first labelled night after an
/// upgrade, can never blank the uncovered part of a window. That is the difference from choosing one
/// transport for a whole window, which dropped every legacy beat as soon as one labelled beat entered it.
///
/// WHOOP 5 precedence, highest first:
///   1. `srcChannel` 5 — labelled v18 history, milliseconds.
///   2. `transport` historical without a label — the same native history, written before labels existed.
///   3. `srcChannel` 7 — labelled standard 0x2A37, read as raw milliseconds (#2195).
///   4. `srcChannel` 6 — labelled native live.
///   5. `transport` realtime without a label — native live before labels.
///   6. `transport` standard without a label — standard 0x2A37 CONVERTED from 1/1024 s per the BLE spec,
///      which a WHOOP 5 does not follow. Stored 2.34 % low, so the read restores the raw value.
///   7. No provenance at all — rows older than the `transport` column. Kept wherever nothing better
///      covers them: they are what this install scored before, and dropping them blanked HRV and Charge.
///
/// Every other device keeps the original order: standard > historical > realtime > untagged.
enum RRTransportReconciler {
    static let overlapRadiusSeconds = 3

    static func reconcile(_ rows: [RRInterval], whoop5: Bool = false) -> [RRInterval] {
        guard rows.contains(where: { $0.transport != nil || $0.srcChannel?.isWhoop5Transport == true })
        else { return rows }

        // rrIntervals supplies timestamp-ordered rows, and compactMap preserves that order, so each
        // per-rank list is already sorted for the binary search.
        let ranks = rows.map { rank($0, whoop5: whoop5) }
        var timesByRank: [Int: [Int]] = [:]
        for (row, rowRank) in zip(rows, ranks) where rowRank > 0 {
            timesByRank[rowRank, default: []].append(row.ts)
        }
        let presentRanks = timesByRank.keys.sorted()

        var out: [RRInterval] = []
        out.reserveCapacity(rows.count)
        for (row, rowRank) in zip(rows, ranks) {
            let covered = presentRanks.contains { higher in
                higher > rowRank && hasNearby(row.ts, in: timesByRank[higher] ?? [])
            }
            guard !covered else { continue }
            out.append(whoop5 ? restoringWhoop5StandardUnits(row) : row)
        }
        return out
    }

    /// Higher wins inside the overlap radius. Zero is "no provenance".
    static func rank(_ row: RRInterval, whoop5: Bool) -> Int {
        guard whoop5 else {
            switch row.transport {
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
