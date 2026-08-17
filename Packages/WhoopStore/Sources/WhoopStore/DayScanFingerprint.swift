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

    public init(day: String, ownerId: String, hrCount: Int, hrMaxTs: Int, nightlySkinC: Double?) {
        self.day = day
        self.ownerId = ownerId
        self.hrCount = hrCount
        self.hrMaxTs = hrMaxTs
        self.nightlySkinC = nightlySkinC
    }

    /// True when `self` was computed from the same inputs `other` describes. Compares ONLY the input
    /// fields — `nightlySkinC` is an output carried along for baseline re-seeding, so including it would
    /// make a day look "changed" because of its own result.
    public func inputsMatch(_ other: DayScanFingerprint) -> Bool {
        ownerId == other.ownerId && hrCount == other.hrCount && hrMaxTs == other.hrMaxTs
    }
}

extension WhoopStore {
    /// Every stored fingerprint for `deviceId` in `[from, to]` (inclusive, `yyyy-MM-dd` lexicographic),
    /// keyed by day. Read ONCE before the scan loop so the per-day check costs no query.
    public nonisolated func dayScanFingerprints(deviceId: String, from: String, to: String) async throws
        -> [String: DayScanFingerprint] {
        try await asyncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT day, ownerId, hrCount, hrMaxTs, nightlySkinC FROM dayScanFingerprint
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])
            var out: [String: DayScanFingerprint] = [:]
            for r in rows {
                out[r["day"]] = DayScanFingerprint(day: r["day"], ownerId: r["ownerId"],
                                                   hrCount: r["hrCount"], hrMaxTs: r["hrMaxTs"],
                                                   nightlySkinC: r["nightlySkinC"])
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
                INSERT INTO dayScanFingerprint (deviceId, day, ownerId, hrCount, hrMaxTs, nightlySkinC)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET
                    ownerId = excluded.ownerId,
                    hrCount = excluded.hrCount,
                    hrMaxTs = excluded.hrMaxTs,
                    nightlySkinC = excluded.nightlySkinC
                """)
            for r in rows {
                try stmt.execute(arguments: [deviceId, r.day, r.ownerId, r.hrCount, r.hrMaxTs, r.nightlySkinC])
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
