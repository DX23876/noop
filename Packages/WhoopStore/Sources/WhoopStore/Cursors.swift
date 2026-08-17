import Foundation
import GRDB

extension WhoopStore {
    public func setCursor(_ name: String, _ value: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO cursors (name, value) VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET value = excluded.value
                """, arguments: [name, value])
        }
    }
    public func cursor(_ name: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?", arguments: [name])
        }
    }
    public func setHighwater(_ stream: String, _ ts: Int) async throws { try await setCursor("highwater:" + stream, ts) }
    public func highwater(_ stream: String) async throws -> Int? { try await cursor("highwater:" + stream) }

    // MARK: - Read highwater (server-pull cursor)
    // A DISTINCT "read:" prefix so the pull cursor never collides with the upload "highwater:"
    // cursor for the same stream. Tracks the max server ts pulled-and-upserted per stream so
    // pulls are incremental.
    public func setReadHighwater(_ stream: String, _ ts: Int) async throws { try await setCursor("read:" + stream, ts) }
    public func readHighwater(_ stream: String) async throws -> Int? { try await cursor("read:" + stream) }

    // MARK: - Sensor-write sequence (the analyze gate's change-detector)

    /// Cursor name for the monotone sensor-write sequence. A plain `cursors` row, so this needs no
    /// migration and rides the same table the offload highwaters already use.
    static let sensorWriteSeqCursor = "seq:sensorwrite"

    /// Bump the sensor-write sequence. MUST be called from inside the SAME transaction as the
    /// mutation it describes, so a rolled-back write can never leave the sequence advanced past data
    /// that does not exist.
    ///
    /// MONOTONE, never a row count. The analyze gate only needs to answer "did anything change since
    /// my last run", and a *counter* answers that wrongly: a heal `DELETE` of N rows followed by a
    /// re-sync of N rows returns the count to its old value, the gate reports "unchanged", and the
    /// re-score it guards silently stops running — which is exactly how the previous `hrFingerprint`
    /// gate went blind (#836 / C1). A sequence that only ever increases cannot come back.
    static func bumpSensorWriteSeq(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO cursors (name, value) VALUES (?, 1)
            ON CONFLICT(name) DO UPDATE SET value = value + 1
            """, arguments: [sensorWriteSeqCursor])
    }

    /// The current sensor-write sequence; 0 before the first sensor mutation of this install.
    ///
    /// Replaces `syncedRowCount()` in the analyze gate. That one answered the same question by
    /// counting every row of every sensor table — 15.3 M rows / 1.7 GB on a real library, measured at
    /// 11 s per call, paid at the TOP of every `analyzeRecent` including the idle ticks that then
    /// short-circuit and do no work at all. This is one indexed row.
    ///
    /// Upgrade behaviour: an install whose stored watermark is an old `syncedRowCount` value reads a
    /// sequence that differs from it, so exactly one extra re-score runs and the watermark converges
    /// onto the new scheme. That is the safe direction — an extra pass, never a missed one.
    public nonisolated func sensorWriteSeq() async throws -> Int {
        try await asyncRead { db in
            try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?",
                             arguments: [WhoopStore.sensorWriteSeqCursor]) ?? 0
        }
    }
}
