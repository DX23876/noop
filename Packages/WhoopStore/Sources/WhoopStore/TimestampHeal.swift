import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Outcome of a one-time implausible-timestamp heal (#547). `rawRowsDeleted` = garbage raw stream
    /// rows purged (HR/RR/SpO2/skinTemp/resp/gravity/step/ppgHr/event/battery). `computedRowsDeleted` =
    /// future/implausible computed daily-metric + sleep-session rows purged. `didChange` is true when
    /// anything was deleted, so the caller can trigger a single rescore instead of always re-running it.
    public struct TimestampHealResult: Equatable, Sendable {
        public let rawRowsDeleted: Int
        public let computedRowsDeleted: Int
        /// Compact union of raw UTC-day buckets changed by the repair. Computed-only cleanup has no
        /// raw-input interval and therefore leaves this nil.
        public let affectedUTCInterval: Range<Int>?
        public var didChange: Bool { rawRowsDeleted > 0 || computedRowsDeleted > 0 }
        public init(rawRowsDeleted: Int, computedRowsDeleted: Int,
                    affectedUTCInterval: Range<Int>? = nil) {
            self.rawRowsDeleted = rawRowsDeleted
            self.computedRowsDeleted = computedRowsDeleted
            self.affectedUTCInterval = affectedUTCInterval
        }
    }

    /// ONE-TIME repair of a database polluted by a bad-clock strap (#547, pikapik). Before the ingest
    /// gate landed, NOOP trusted each type-47 record's own unix timestamp verbatim, so a WHOOP with a
    /// broken clock/flash (repeated trim=0xFFFFFFFF) wrote rows dated to scattered garbage — far-past
    /// (2024/2029), a bogus 2027=1827642881, and FUTURE dates. The day-windows overlap, so one ~12h
    /// polluted block was re-attributed to every day (the repeated totalSleepMin=721 across 06-14..06-21)
    /// and a future-dated record made the Today "last night" carry-over read "12 Jul".
    ///
    /// This purges that garbage so a normal rescore recomputes the real days cleanly:
    ///   (a) raw stream rows whose `ts` is implausible (< MIN_PLAUSIBLE_UNIX or > now + FUTURE_MARGIN) —
    ///       across every time-keyed raw table the gate now protects;
    ///   (b) computed `dailyMetric` rows whose `day` is in the future (> today, local) or implausibly old,
    ///       and `sleepSession` rows whose `startTs` is future/implausible.
    /// The caller then triggers a normal `analyzeRecent` so the real days recompute (the 721 block is
    /// gone once its garbage raw rows are purged). Idempotent: a re-run on a clean DB deletes nothing.
    ///
    /// `now` and `todayLocalDayKey` are injected (default to the live wall clock / today's yyyy-MM-dd in
    /// the local zone) so the heal is deterministically unit-testable. Bounds come straight from
    /// WhoopProtocol so Swift and the Android Room cleanup reject the identical set.
    @discardableResult
    public func healImplausibleTimestamps(
        now: Int = Int(Date().timeIntervalSince1970),
        todayLocalDayKey: String = WhoopStore.localDayKey(Date())
    ) async throws -> TimestampHealResult {
        let lo = MIN_PLAUSIBLE_UNIX
        let hi = now + FUTURE_MARGIN
        return try syncWrite { db in
            // (a) Raw, ts-keyed streams. Every one of these is fed by the historical type-47 / EVENT /
            // REALTIME paths the #547 gate now guards, so the same out-of-bounds predicate cleans them.
            // `ppgWaveformSample` / `rawImuSample` / `sleepStateSample` / `v18AuxSample` were landed after
            // this list and never added to it, so a bad-clock strap's garbage-ts rows in those tables
            // survived a heal that cleaned every sibling stream — the rows are keyed by the SAME `ts` from
            // the SAME type-47 ingest path, so there is no reason for them to be exempt. This is a
            // legacy-rows gap rather than an ongoing one (the #547 ingest gate now rejects an implausible
            // ts before it is banked), which is exactly why it went unnoticed. Guarded by the same
            // out-of-bounds predicate as everything else — a plausible row is never touched.
            let rawTables = ["hrSample", "rrInterval", "event", "battery",
                             "spo2Sample", "skinTempSample", "respSample",
                             "gravitySample", "stepSample", "ppgHrSample",
                             "sleepStateSample", "ppgWaveformSample", "rawImuSample", "v18AuxSample"]
            var rawDeleted = 0
            var affectedBuckets: [String: Set<Int>] = [:]
            for table in rawTables {
                // Capture compact day buckets before deleting them. This one-time repair may remove many
                // rows, but the number of distinct (device, UTC-day) pairs stays small.
                for row in try Row.fetchAll(db, sql: """
                    SELECT deviceId, CAST(ts / 86400 AS INTEGER) AS utcDay
                    FROM \(table) WHERE ts < ? OR ts > ?
                    GROUP BY deviceId, CAST(ts / 86400 AS INTEGER)
                    """, arguments: [lo, hi]) {
                    affectedBuckets[row["deviceId"], default: []].insert(row["utcDay"])
                }
                try db.execute(sql: "DELETE FROM \(table) WHERE ts < ? OR ts > ?",
                               arguments: [lo, hi])
                rawDeleted += db.changesCount
            }

            // (b) Computed rows. dailyMetric is keyed by a yyyy-MM-dd `day` text; sleepSession by an
            // integer `startTs`. A FUTURE-dated row is always implausible (a future day/ts can only come
            // from a future-dated record), so drop it regardless of source. The far-PAST floor, though, is
            // applied ONLY to computed (`-noop`) rows: those can't legitimately predate NOOP, so a pre-2023
            // one is bad-clock garbage — but a WHOOP CSV import (bare "my-whoop") carries REAL dates going
            // back years, and reusing the floor across all sources silently purged that imported history on
            // any heal (v8.2.1). String comparison is correct for the zero-padded yyyy-MM-dd format.
            let floorDayKey = WhoopStore.utcDayKey(MIN_PLAUSIBLE_UNIX)
            var computedDeleted = 0
            try db.execute(sql: "DELETE FROM dailyMetric WHERE day > ? OR (day < ? AND deviceId LIKE '%-noop')",
                           arguments: [todayLocalDayKey, floorDayKey])
            computedDeleted += db.changesCount
            try db.execute(sql: "DELETE FROM sleepSession WHERE startTs > ? OR (startTs < ? AND deviceId LIKE '%-noop')",
                           arguments: [hi, lo])
            computedDeleted += db.changesCount

            // Invalidate only when something changed. Raw deletions carry their exact UTC buckets;
            // computed-only cleanup still advances the global gate so the forced repair pass cannot be
            // mistaken for an idle tick.
            for (deviceId, buckets) in affectedBuckets {
                try WhoopStore.markAnalysisInputsChanged(
                    db, deviceId: deviceId, timestamps: buckets.map { $0 * 86_400 })
            }
            if rawDeleted == 0, computedDeleted > 0 { try WhoopStore.bumpSensorWriteSeq(db) }
            let allBuckets = affectedBuckets.values.flatMap { $0 }
            let affectedInterval: Range<Int>? = allBuckets.min().flatMap { lowerDay in
                allBuckets.max().map { upperDay in
                    (lowerDay * 86_400)..<((upperDay + 1) * 86_400)
                }
            }
            return TimestampHealResult(rawRowsDeleted: rawDeleted,
                                       computedRowsDeleted: computedDeleted,
                                       affectedUTCInterval: affectedInterval)
        }
    }

    /// `yyyy-MM-dd` for `date` in the LOCAL calendar — matches how dailyMetric `day` keys are written.
    public static func localDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `yyyy-MM-dd` for a unix second in UTC — a zone-independent sentinel for the far-past floor day.
    public static func utcDayKey(_ unix: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
