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
    /// Richness is a RANK, not a yes/no. Presence alone was the original test, and it cannot see a
    /// device-provided hypnogram assembled from records that arrived incomplete: such a row carries many
    /// segments — so it passes any presence check — while covering a fraction of the span it claims
    /// (measured: one ring night with 21 segments over 23% of its 601-minute span, stored as 70 minutes
    /// of sleep against a paired strap's 494). So a day's best session ranks:
    ///
    ///   2  stages that cover the span they claim (`HypnogramCoverage`)
    ///   1  stages present but HOLED — real, but describing only part of the night
    ///   0  no stages at all
    ///
    /// and the computed day wins only when it OUT-RANKS the import. Collapsing 1 and 0 together gives
    /// back the original presence rule exactly, so this is a strict generalisation: every case #240
    /// decided, it still decides the same way. What changes is the pair the old rule could not express
    /// — a holed import against a COMPLETE computed night, which used to go to the import and now goes
    /// to the night that actually covers itself. A holed import still beats no stages at all: partial
    /// data is better than none, it just no longer outranks a whole night.
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
               dayRichness(comp) > dayRichness(imp) {
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

    /// How much of a night this session's stages actually describe: 2 = covers its span, 1 = present but
    /// holed, 0 = none. A timeline whose coverage cannot be measured (the imported minute-dict shape,
    /// which has no timestamps) is never holed, so it ranks 2 — imports keep being judged on presence
    /// exactly as they always were, and this gate cannot reach them.
    static func richness(_ s: CachedSleepSession) -> Int {
        guard hasStages(s) else { return 0 }
        return HypnogramCoverage.isHoled(s) ? 1 : 2
    }

    /// A day's richness is that of its BEST session — a day with a fully-staged main night plus an
    /// unstaged nap is a staged day (#715 keeps every session of the winning day either way).
    static func dayRichness(_ sessions: [CachedSleepSession]) -> Int {
        sessions.reduce(0) { max($0, richness($1)) }
    }
}
