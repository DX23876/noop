import Foundation
import WhoopProtocol

/// Selects one WHOOP R-R delivery path when transports overlap.
///
/// Rows stay in SQLite for diagnostics and future reprocessing. This read-side selection prefers the
/// standard Heart Rate service, then historical offload, then proprietary realtime. A tagged stream also
/// replaces legacy untagged rows only near timestamps it actually covers, so a partial offload cannot
/// erase an uncovered part of a night.
enum RRTransportReconciler {
    static let overlapRadiusSeconds = 3

    static func reconcile(_ rows: [RRInterval]) -> [RRInterval] {
        guard rows.contains(where: { $0.transport != nil }) else { return rows }

        // rrIntervals supplies timestamp-ordered rows, and compactMap preserves that order. Avoid three
        // redundant O(n log n) sorts on the analysis path, which commonly reads an entire night.
        let taggedTimes = rows.compactMap { row in row.transport == nil ? nil : row.ts }
        let standardTimes = rows.compactMap { row in
            row.transport == .standardHeartRate ? row.ts : nil
        }
        let historicalTimes = rows.compactMap { row in
            row.transport == .whoopHistorical ? row.ts : nil
        }

        return rows.filter { row in
            switch row.transport {
            case nil:
                return !hasNearby(row.ts, in: taggedTimes)
            case .standardHeartRate:
                return true
            case .whoopHistorical:
                return !hasNearby(row.ts, in: standardTimes)
            case .whoopRealtime:
                return !hasNearby(row.ts, in: standardTimes)
                    && !hasNearby(row.ts, in: historicalTimes)
            }
        }
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
