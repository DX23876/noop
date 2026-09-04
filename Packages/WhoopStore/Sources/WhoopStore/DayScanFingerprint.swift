import Foundation
import GRDB

/// What one scored day was computed FROM — the record that lets the analyze scan skip a day whose
/// inputs have not moved.
///
/// `analyzeRecent` re-derives every day in its window from the raw streams on every run. Each day is a
/// ~54 h read window (~950 k rows on a fully-worn library) plus sleep staging, and the window overlaps
/// its neighbours, so a 21-day pass reads more rows than the whole database holds. Almost none of that
/// work is needed: on a real install the window is covered by days that were scored days ago and have
/// not changed since.
///
/// The comparison is deliberately over the RAW INPUTS, not over the scored output: a day is safe to skip
/// only when the bytes it was computed from are the same AND it was read from the same owner. Anything
/// else — a backfilled old night, a re-pointed device, a fingerprint we simply do not have — falls
/// through to a full scan. Missing always means "scan it".
public struct DayScanFingerprint: Equatable, Sendable {
    public let day: String
    public let ownerId: String
    public let hrCount: Int
    public let hrMaxTs: Int
    /// The night's raw skin-temp mean (°C-scale value the skin baseline folds), or nil when the night had
    /// none. Carried here because the scored `dailyMetric` row stores only the DEVIATION — without this a
    /// skipped day could not re-seed the skin baseline the way a scanned one does, and the baseline (and
    /// therefore every score folded off it) would depend on which days happened to be skipped.
    public let nightlySkinC: Double?
    /// The LEARNED traits this day was scored against, quantised. They are re-derived from the trailing
    /// history on every pass and fed into the day's scoring, so they move a day's stored Rest score
    /// without moving one byte of its raw input — the (count, maxTs) probe cannot see them.
    ///
    /// nil means "not recorded" (a row from v38, before this existed) and compares as CHANGED, so such a
    /// day is re-derived once and gains its traits. Missing means scan.
    public let traits: TraitSignature?
    /// Monotone revisions covering every scoring-relevant raw stream in this day's exact read window.
    /// nil identifies a legacy HR-only row and is never reusable.
    public let inputRevision: Int?
    public let deviceRevision: Int?
    /// Explicit analytics contract version. Algorithm changes bump this even when raw bytes do not move.
    public let scoringVersion: Int?
    /// Stable signature of profile/configuration inputs consumed by scoring.
    public let semanticSignature: String?

    /// The three learned traits, quantised to the resolution at which a change is worth re-deriving a
    /// day for. Raw `Double`s would differ in the last bits every single night — the 28-night regularity
    /// window alone shifts with every new night — and the whole window would invalidate daily, which is
    /// the cost this table exists to avoid. Integers also compare exactly, with no float-equality trap.
    ///
    /// Resolutions: consistency to 1/100 (its own range is 0…1), sleep need to 0.1 h (6 min — finer than
    /// the Rest scorer can express), midsleep to the minute. Each is roughly "a change a wearer could
    /// notice in the score", so a real drift invalidates and ordinary jitter does not.
    public struct TraitSignature: Equatable, Sendable {
        public let consistencyHundredths: Int?
        public let needHoursTenths: Int
        public let midsleepMinutes: Int?

        public init(consistency: Double?, needHours: Double, midsleepSec: Int?) {
            self.consistencyHundredths = consistency.map { Int(($0 * 100).rounded()) }
            self.needHoursTenths = Int((needHours * 10).rounded())
            self.midsleepMinutes = midsleepSec.map { Int((Double($0) / 60).rounded()) }
        }

        public init(consistencyHundredths: Int?, needHoursTenths: Int, midsleepMinutes: Int?) {
            self.consistencyHundredths = consistencyHundredths
            self.needHoursTenths = needHoursTenths
            self.midsleepMinutes = midsleepMinutes
        }
    }

    public init(day: String, ownerId: String, hrCount: Int, hrMaxTs: Int, nightlySkinC: Double?,
                traits: TraitSignature? = nil, inputRevision: Int? = nil,
                deviceRevision: Int? = nil, scoringVersion: Int? = nil,
                semanticSignature: String? = nil) {
        self.day = day
        self.ownerId = ownerId
        self.hrCount = hrCount
        self.hrMaxTs = hrMaxTs
        self.nightlySkinC = nightlySkinC
        self.traits = traits
        self.inputRevision = inputRevision
        self.deviceRevision = deviceRevision
        self.scoringVersion = scoringVersion
        self.semanticSignature = semanticSignature
    }

    /// True when `self` was computed from the same inputs `other` describes — raw AND learned.
    ///
    /// `nightlySkinC` is deliberately excluded: it is an OUTPUT carried along so a reused day can
    /// re-seed the skin baseline, and comparing it would make every skin-bearing night look changed
    /// because of its own result.
    ///
    /// A nil `traits` on EITHER side is a mismatch, not a pass. `self` is the stored record and `other`
    /// the current probe; an unrecorded trait set means we cannot show the day was scored against
    /// today's traits, and "cannot show" has to read the same as "was not".
    public func inputsMatch(_ other: DayScanFingerprint) -> Bool {
        reuseMisses(other).isEmpty
    }

    /// Which individual conditions of `inputsMatch` fail, ALL of them, in a stable order. Empty means
    /// the day may be reused — `inputsMatch` is defined as exactly that, so the verdict and its
    /// explanation can never drift apart.
    ///
    /// This exists because `reused=0 of 21` on a device was indistinguishable from `reused=0` for any
    /// other reason: the Bool says a day was re-derived, never which of six conditions decided it, and
    /// five of the six are PASS-GLOBAL (they either pass for every day or fail for every day). Knowing
    /// which one flipped is the difference between a cache bug and a scoring-dependency problem.
    ///
    /// Nil-handling matches `inputsMatch`'s rule exactly: a nil on EITHER side counts as a miss, not a
    /// pass. `self` is the stored record, `other` the current probe; an unrecorded value cannot show the
    /// day was scored against today's inputs, and "cannot show" has to read the same as "was not".
    public func reuseMisses(_ other: DayScanFingerprint) -> [ReuseMiss] {
        var misses: [ReuseMiss] = []
        if ownerId != other.ownerId { misses.append(.owner) }
        if inputRevision == nil || other.inputRevision == nil
            || inputRevision != other.inputRevision { misses.append(.inputRevision) }
        if deviceRevision == nil || other.deviceRevision == nil
            || deviceRevision != other.deviceRevision { misses.append(.deviceRevision) }
        if scoringVersion == nil || other.scoringVersion == nil
            || scoringVersion != other.scoringVersion { misses.append(.scoringVersion) }
        if semanticSignature == nil || other.semanticSignature == nil
            || semanticSignature != other.semanticSignature { misses.append(.semanticSignature) }
        if traits == nil || other.traits == nil || traits != other.traits { misses.append(.traits) }
        return misses
    }

    /// One condition of `inputsMatch`. `owner`, `deviceRevision`, `scoringVersion`, `semanticSignature`
    /// and `traits` are PASS-GLOBAL — a pass computes one value for the whole window, so each either
    /// passes for every day or fails for every day. Only `inputRevision` is per-day. That asymmetry is
    /// the whole diagnostic value: a summary showing 20 misses on a pass-global condition names the
    /// cause outright, while 1–2 on `inputRevision` is ordinary new data.
    public enum ReuseMiss: String, CaseIterable, Sendable {
        case owner, inputRevision, deviceRevision, scoringVersion, semanticSignature, traits
    }
}

extension WhoopStore {
    /// Every stored fingerprint for `deviceId` in `[from, to]` (inclusive, `yyyy-MM-dd` lexicographic),
    /// keyed by day. Read ONCE before the scan loop so the per-day check costs no query.
    public nonisolated func dayScanFingerprints(deviceId: String, from: String, to: String) async throws
        -> [String: DayScanFingerprint] {
        try await asyncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT day, ownerId, hrCount, hrMaxTs, nightlySkinC,
                       traitSleepConsistency, traitNeedHoursTenths, traitMidsleepMin,
                       inputRevision, deviceRevision, scoringVersion, semanticSignature
                FROM dayScanFingerprint
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])
            var out: [String: DayScanFingerprint] = [:]
            for r in rows {
                // `needHoursTenths` is the one non-optional member of the signature, so a row whose need
                // is NULL predates v39 and has no recorded traits at all — surfaced as nil, which
                // `inputsMatch` treats as CHANGED.
                let traits: DayScanFingerprint.TraitSignature? = (r["traitNeedHoursTenths"] as Int?).map {
                    DayScanFingerprint.TraitSignature(
                        consistencyHundredths: r["traitSleepConsistency"],
                        needHoursTenths: $0,
                        midsleepMinutes: r["traitMidsleepMin"])
                }
                out[r["day"]] = DayScanFingerprint(day: r["day"], ownerId: r["ownerId"],
                                                   hrCount: r["hrCount"], hrMaxTs: r["hrMaxTs"],
                                                   nightlySkinC: r["nightlySkinC"], traits: traits,
                                                   inputRevision: r["inputRevision"],
                                                   deviceRevision: r["deviceRevision"],
                                                   scoringVersion: r["scoringVersion"],
                                                   semanticSignature: r["semanticSignature"])
            }
            return out
        }
    }

    /// Record what the given days were scored from. Upsert by (deviceId, day), so a re-scored day
    /// replaces its own record and a day scored for the first time gains one.
    ///
    /// Call this ONLY for days whose scores were actually persisted in the same pass. A fingerprint
    /// written for a day whose scores were not stored would make the next run skip a day that has no
    /// result — the one direction this table must never fail in.
    @discardableResult
    public func upsertDayScanFingerprints(_ rows: [DayScanFingerprint], deviceId: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO dayScanFingerprint (deviceId, day, ownerId, hrCount, hrMaxTs, nightlySkinC,
                                                traitSleepConsistency, traitNeedHoursTenths, traitMidsleepMin,
                                                inputRevision, deviceRevision, scoringVersion, semanticSignature)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET
                    ownerId = excluded.ownerId,
                    hrCount = excluded.hrCount,
                    hrMaxTs = excluded.hrMaxTs,
                    nightlySkinC = excluded.nightlySkinC,
                    traitSleepConsistency = excluded.traitSleepConsistency,
                    traitNeedHoursTenths = excluded.traitNeedHoursTenths,
                    traitMidsleepMin = excluded.traitMidsleepMin,
                    inputRevision = excluded.inputRevision,
                    deviceRevision = excluded.deviceRevision,
                    scoringVersion = excluded.scoringVersion,
                    semanticSignature = excluded.semanticSignature
                """)
            for r in rows {
                try stmt.execute(arguments: [deviceId, r.day, r.ownerId, r.hrCount, r.hrMaxTs, r.nightlySkinC,
                                             r.traits?.consistencyHundredths, r.traits?.needHoursTenths,
                                             r.traits?.midsleepMinutes, r.inputRevision, r.deviceRevision,
                                             r.scoringVersion, r.semanticSignature])
            }
            return rows.count
        }
    }

    /// Drop every stored fingerprint for `deviceId`, so the next pass re-scans the whole window from raw.
    /// The escape hatch behind a "recompute everything" action and behind any change that alters what
    /// scoring PRODUCES from unchanged inputs — an algorithm change moves no raw byte, so the input
    /// fingerprints would still match and the new algorithm would never reach the old days.
    @discardableResult
    public func clearDayScanFingerprints(deviceId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM dayScanFingerprint WHERE deviceId = ?", arguments: [deviceId])
            return db.changesCount
        }
    }
}
