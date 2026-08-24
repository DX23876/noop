import Foundation
import WhoopStore

/// Applies one hand-corrected bed/wake window to every fragment of a bridged night.
///
/// The sleep UI presents a bridged group as one night, but each fragment keeps its own immutable
/// `(deviceId, startTs)` database key. Editing only the selector's winning fragment leaves the rows at
/// the displayed edges untouched, so the visible times do not move and the next analysis pass can fold
/// those rows straight back into the night. This pure planner makes the displayed group the edit unit.
public enum SleepGroupEdit {

    public struct Plan: Equatable {
        /// Fragments that survive the corrected window, carrying their corrected bounds and re-clipped
        /// stored stages. The repository may replace `stagesJSON` with a raw-data re-stage before writing.
        public let clipped: [CachedSleepSession]
        /// Fragments wholly outside the corrected window. The repository must retire/tombstone these so
        /// the detector cannot immediately recreate the old displayed edge.
        public let dropped: [CachedSleepSession]

        public init(clipped: [CachedSleepSession], dropped: [CachedSleepSession]) {
            self.clipped = clipped
            self.dropped = dropped
        }
    }

    /// Return the full displayed window of a bridged night.
    public static func groupWindow(_ group: [CachedSleepSession]) -> (start: Int, end: Int)? {
        guard let start = group.map(\.effectiveStartTs).min(),
              let end = group.map(\.endTs).max(), end > start else { return nil }
        return (start, end)
    }

    /// Re-cut `group` to `[newStartTs, newEndTs)`.
    ///
    /// The first and last surviving fragments take the user's bounds outright, which permits extending a
    /// truncated night as well as shortening one. Interior fragments only narrow. A completely disjoint
    /// edit returns an empty plan: changing times must never silently mean deleting the whole night.
    public static func plan(_ group: [CachedSleepSession], newStartTs: Int,
                            newEndTs: Int) -> Plan {
        guard !group.isEmpty, newEndTs > newStartTs else { return Plan(clipped: [], dropped: []) }
        let ordered = group.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let kept = ordered.filter {
            min($0.endTs, newEndTs) > max($0.effectiveStartTs, newStartTs)
        }
        guard !kept.isEmpty else { return Plan(clipped: [], dropped: []) }
        let keptKeys = Set(kept.map(\.startTs))
        let dropped = ordered.filter { !keptKeys.contains($0.startTs) }

        let clipped = kept.enumerated().map { index, fragment -> CachedSleepSession in
            let start = index == 0 ? newStartTs : max(fragment.effectiveStartTs, newStartTs)
            let end = index == kept.count - 1 ? newEndTs : min(fragment.endTs, newEndTs)
            let stages = SleepWindowReclip.reclip(
                stagesJSON: fragment.stagesJSON,
                sessionStart: fragment.effectiveStartTs,
                oldEnd: fragment.endTs,
                newStart: start,
                newEnd: end
            ) ?? fragment.stagesJSON
            return CachedSleepSession(
                startTs: fragment.startTs,
                endTs: end,
                efficiency: fragment.efficiency,
                restingHr: fragment.restingHr,
                avgHrv: fragment.avgHrv,
                stagesJSON: stages,
                userEdited: true,
                startTsAdjusted: start,
                stagingSparse: fragment.stagingSparse
            )
        }
        return Plan(clipped: clipped, dropped: dropped)
    }
}
