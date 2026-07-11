import Foundation

/// Merge imported and on-device-computed sleep sessions for display and export.
public enum SleepMerge {
    /// Merge imported + computed sleep, preserving EVERY session.
    ///
    /// A day with two sessions (e.g. a main night and an afternoon nap, or two nights ending the same
    /// local day) must keep BOTH — the previous per-day dictionary overwrote on collision and silently
    /// dropped one (#715). Imported sessions take precedence per day: if any imported session ends on a
    /// given local day, the computed sessions for that day yield to it (the existing imported-over-computed
    /// rule); on days with no imported session the computed sessions stand. Result is sorted by start time.
    ///
    /// Richness exception: a sparse import (no stage data on ANY of its sessions that day) must not
    /// clobber a computed day that HAS stage data — otherwise a stage-less WHOOP/Apple re-import blanks
    /// the stage breakdown for a night the strap fully staged. Days where the import carries stages, or
    /// where neither side does, keep the imported-over-computed rule unchanged. (Swift twin of the
    /// Android HealthConnectImporter richness fix, ryanbr/noop#240.)
    ///
    /// - Parameter endDay: maps a session to its canonical LOCAL end-day key (callers inject their
    ///   timezone-aware keyer so this stays pure and testable).
    public static func merge(imported: [CachedSleepSession],
                             computed: [CachedSleepSession],
                             endDay: (CachedSleepSession) -> String) -> [CachedSleepSession] {
        var importedByDay: [String: [CachedSleepSession]] = [:]
        for s in imported { importedByDay[endDay(s), default: []].append(s) }
        var computedByDay: [String: [CachedSleepSession]] = [:]
        for s in computed { computedByDay[endDay(s), default: []].append(s) }

        var out: [CachedSleepSession] = []
        out.reserveCapacity(imported.count + computed.count)
        for (day, imp) in importedByDay {
            if let comp = computedByDay[day],
               !imp.contains(where: hasStages),
               comp.contains(where: hasStages) {
                out.append(contentsOf: comp)   // richer computed day survives a stage-less import
            } else {
                out.append(contentsOf: imp)    // imported wins its day (unchanged rule)
            }
        }
        for (day, comp) in computedByDay where importedByDay[day] == nil {
            out.append(contentsOf: comp)
        }
        return out.sorted { $0.startTs < $1.startTs }
    }

    /// True when the session carries a non-empty stage payload; nil, "", and "[]" carry none.
    static func hasStages(_ s: CachedSleepSession) -> Bool {
        guard let json = s.stagesJSON?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !json.isEmpty && json != "[]"
    }
}
