import Foundation
import GRDB

// MARK: - v43 store: body-weight measurements
//
// BodyWeightStore.swift — GRDB CRUD over the `bodyWeightEntry` table (migration v43), the
// source-of-truth for weigh-ins the user records in NOOP itself.
//
// The book is `bodyWeightEntry` (one row per dated measurement); the daily `metricSeries`
// projection under source id `noop-weight` is HOW it talks to the rest of the app — Compare,
// Explore, correlation, goal tracking and the Coach read a metric series and need no knowledge
// of this table. On every write this store ALSO upserts that daily projection, so the two can
// never drift. Mirrors `LabMarkerStore` precisely, which solved the identical shape for lab
// readings: plain Codable row struct, raw `Row` fetch + manual decode, idempotent upserts keyed
// by the natural key, all GRDB work via the actor's `syncWrite` / `syncRead` helpers.
//
// NOT a copy of Apple Health. Health-imported weights keep living in their own `apple-health`
// series; `Repository.weightSeries()` unions the two per day. HealthKit samples can be edited
// and deleted after the fact, so copying them here would create a second, diverging truth and
// a permanent reconciliation problem.

/// One stored weigh-in. The natural key (deviceId, takenAt, source) is enforced by a UNIQUE
/// index so re-logging or re-importing the same measurement is idempotent; `id` is a stable
/// client-generated identifier for edit/delete-by-id and backup round-trips.
public struct BodyWeightRow: Equatable, Codable, Sendable {
    /// Where a measurement came from. Kept as a string in the column (like `labMarker.source`)
    /// so a future source needs no migration; this enum is the vocabulary callers should use.
    public enum Source: String, Equatable, Sendable, Codable, CaseIterable {
        /// The user typed it into NOOP.
        case manual
        /// Recorded by Apple Health and surfaced here (reserved — the union resolver reads
        /// Health's own series directly, so nothing writes this today).
        case appleHealth
        /// Came in through a file import.
        case imported
    }

    public var id: String
    public var deviceId: String
    /// Pre-derived yyyy-MM-dd day key (the projection key for this measurement).
    public var day: String
    /// Precise instant the measurement was taken (epoch seconds).
    public var takenAt: Int
    public var weightKg: Double
    public var source: String
    public var note: String?

    public init(
        id: String,
        deviceId: String,
        day: String,
        takenAt: Int,
        weightKg: Double,
        source: String,
        note: String? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.day = day
        self.takenAt = takenAt
        self.weightKg = weightKg
        self.source = source
        self.note = note
    }

    /// Decode a GRDB row (raw-Row idiom, matching `LabMarkerRow.decode`).
    static func decode(_ row: Row) -> BodyWeightRow {
        BodyWeightRow(
            id: row["id"],
            deviceId: row["deviceId"],
            day: row["day"],
            takenAt: row["takenAt"],
            weightKg: row["weightKg"],
            source: row["source"],
            note: row["note"]
        )
    }
}

extension WhoopStore {

    /// The constant device-id the daily weight projection is written under, so Compare / Explore /
    /// goal tracking / Coach see NOOP-logged weigh-ins as one ordinary single-source series.
    /// Deliberately distinct from `apple-health`: keeping them separate is what lets the resolver
    /// choose per day and label which source a value came from.
    public static let noopWeightSourceId = "noop-weight"

    /// The metric key both the projection and Apple Health's own import use.
    public static let bodyWeightMetricKey = "weight"

    // MARK: - Upsert (idempotent by natural key) + project to metricSeries

    /// Upsert weigh-ins, then re-project the affected days into `metricSeries` under
    /// `noop-weight`. Idempotent: re-upserting the same (deviceId, takenAt, source) updates that
    /// measurement in place (UNIQUE index `idx_bodyWeightEntry_natural`) and the projection
    /// reflects the new value.
    ///
    /// The daily projection rule is LATEST-per-day: the measurement with the greatest `takenAt`
    /// for a day wins — the same rule Apple's own import applies (`.discreteMostRecent`), so the
    /// two series mean the same thing before the resolver ever compares them.
    ///
    /// Returns the number of rows written/updated.
    @discardableResult
    public func upsertBodyWeights(_ rows: [BodyWeightRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var written = 0
            var touched: Set<DayCell> = []
            for r in rows {
                // Upsert keyed on the natural index, NOT on the `id` PK: re-logging the "same
                // measurement" (same deviceId+takenAt+source) must update, not duplicate, even if
                // the caller minted a fresh id.
                try db.execute(sql: """
                    INSERT INTO bodyWeightEntry
                        (id, deviceId, day, takenAt, weightKg, source, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, takenAt, source) DO UPDATE SET
                        day = excluded.day,
                        weightKg = excluded.weightKg,
                        note = excluded.note
                    """, arguments: [r.id, r.deviceId, r.day, r.takenAt, r.weightKg, r.source, r.note])
                written += db.changesCount
                touched.insert(DayCell(deviceId: r.deviceId, day: r.day))
            }
            try reprojectWeightCells(db, cells: touched)
            return written
        }
    }

    // MARK: - Reads

    /// Full weigh-in history for a device, oldest first (by takenAt). Served index-only by
    /// `idx_bodyWeightEntry_device_takenAt`.
    public func bodyWeights(deviceId: String) async throws -> [BodyWeightRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM bodyWeightEntry
                WHERE deviceId = ?
                ORDER BY takenAt ASC
                """, arguments: [deviceId]).map(BodyWeightRow.decode)
        }
    }

    /// Weigh-ins on days in [from, to] (lexicographic yyyy-MM-dd compare), oldest first.
    public func bodyWeights(deviceId: String, from: String, to: String) async throws -> [BodyWeightRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM bodyWeightEntry
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY takenAt ASC
                """, arguments: [deviceId, from, to]).map(BodyWeightRow.decode)
        }
    }

    /// The most recent weigh-in, or nil when none has been recorded.
    public func latestBodyWeight(deviceId: String) async throws -> BodyWeightRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM bodyWeightEntry
                WHERE deviceId = ?
                ORDER BY takenAt DESC
                LIMIT 1
                """, arguments: [deviceId]).map(BodyWeightRow.decode)
        }
    }

    // MARK: - Delete (removes the row AND re-projects its day)

    /// Delete one weigh-in by `id`. If that was the last measurement for its day, the projected
    /// `metricSeries` day is removed too; otherwise the projection is recomputed from the
    /// remaining same-day measurements. Returns true if a row was deleted.
    @discardableResult
    public func deleteBodyWeight(id: String) async throws -> Bool {
        try syncWrite { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT * FROM bodyWeightEntry WHERE id = ?", arguments: [id]).map(BodyWeightRow.decode) else {
                return false
            }
            try db.execute(sql: "DELETE FROM bodyWeightEntry WHERE id = ?", arguments: [id])
            try reprojectWeightCells(db, cells: [DayCell(deviceId: row.deviceId, day: row.day)])
            return true
        }
    }

    // MARK: - Projection helpers (private)

    /// Identifies one daily projection cell.
    private struct DayCell: Hashable {
        let deviceId: String
        let day: String
    }

    /// Recompute the `metricSeries` projection (under `noop-weight`) for each touched day from the
    /// CURRENT `bodyWeightEntry` rows. Latest-per-day wins; if no measurement remains for a day,
    /// its projected cell is deleted, so a removed last weigh-in never leaves a stale value behind.
    private func reprojectWeightCells(_ db: Database, cells: Set<DayCell>) throws {
        for cell in cells {
            let latest = try Double.fetchOne(db, sql: """
                SELECT weightKg FROM bodyWeightEntry
                WHERE deviceId = ? AND day = ?
                ORDER BY takenAt DESC
                LIMIT 1
                """, arguments: [cell.deviceId, cell.day])

            if let v = latest {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [WhoopStore.noopWeightSourceId, cell.day,
                                     WhoopStore.bodyWeightMetricKey, v])
            } else {
                try db.execute(sql: """
                    DELETE FROM metricSeries
                    WHERE deviceId = ? AND day = ? AND key = ?
                    """, arguments: [WhoopStore.noopWeightSourceId, cell.day,
                                     WhoopStore.bodyWeightMetricKey])
            }
        }
    }
}
