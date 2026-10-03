import Foundation
import GRDB

/// One WHOOP entry per person (fork decision 2026-10-03).
///
/// A new strap used to become a second registry row (`whoop-<uuid>`, later `whoop-<serial>`) next to the
/// seeded `my-whoop`, so replacing a strap left two or three near-identical cards and a history spread
/// across ids. The fold moves every other WHOOP id's rows onto the one canonical id and removes the extra
/// registry rows, so the Devices screen shows one WHOOP and the history lives under one id.
///
/// `my-whoop` is the target because it cannot be the source: the WHOOP export import writes under that
/// literal, the computed `my-whoop-noop` namespace is keyed off it, and #1304 still lists hundreds of reads
/// of the literal. Folding the other way would strand all of those.
///
/// Rows move in short transactions of `chunkSize`, so a fold that is interrupted (app killed, phone out of
/// battery) leaves every row under exactly one id and simply continues on the next run. The extra registry
/// rows are deleted only after their last row has moved, which is also what keeps the fold discoverable
/// until it is complete. A primary-key clash keeps the canonical row, the same rule `adoptSerialIdentity`
/// applies; the source copy of a clashing row is the same strap's reading of the same second.
public struct WhoopRowFold {

    /// The id every WHOOP folds into.
    public static let canonicalId = "my-whoop"

    /// Rows moved per transaction. Small enough that a write lock is held for well under a second on a
    /// phone, large enough that millions of samples take minutes, not hours.
    public static let defaultChunkSize = 20_000

    /// WHOOP ids other than the canonical one: registry rows plus ids that only survive in data (an old
    /// provisional `whoop-<uuid>` whose registry row was re-pointed long ago). `-noop` siblings are not
    /// listed; each source carries its own along.
    public static func sourceIds(in db: Database) throws -> [String] {
        var ids = Set(try String.fetchAll(db, sql: "SELECT id FROM pairedDevice WHERE id LIKE 'whoop-%'"))
        for table in try deviceTables(in: db) {
            ids.formUnion(try distinctWhoopIds(table: table, in: db))
        }
        return ids
            .map { $0.hasSuffix(DeviceRegistryStore.computedSuffix) ? String($0.dropLast(DeviceRegistryStore.computedSuffix.count)) : $0 }
            .filter { $0 != canonicalId }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted()
    }

    /// True when the install has more than one WHOOP id, i.e. a fold has something to do.
    public static func isNeeded(in db: Database) throws -> Bool {
        try !String.fetchAll(db, sql: "SELECT id FROM pairedDevice WHERE id LIKE 'whoop-%' LIMIT 1").isEmpty
    }

    /// Every table with a `deviceId` column, read from the schema rather than a list, so a table added by
    /// a later migration (or one present in a build from another branch) is never left behind.
    static func deviceTables(in db: Database) throws -> [String] {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            AND name NOT IN ('pairedDevice', 'device', 'grdb_migrations')
            """)
        return try tables.filter { table in
            try db.columns(in: table).contains { $0.name == "deviceId" }
        }.sorted()
    }

    /// Distinct `whoop-…` ids in one table by skipping through the index, one lookup per id rather than
    /// a scan of every row.
    static func distinctWhoopIds(table: String, in db: Database) throws -> [String] {
        var found: [String] = []
        var after = "whoop-"
        while let next = try String.fetchOne(db, sql: "SELECT MIN(deviceId) FROM \(table) WHERE deviceId > ?",
                                             arguments: [after]),
              next.hasPrefix("whoop-") {
            found.append(next)
            after = next
        }
        return found
    }

    /// Point the canonical row at the strap that stays and make it the active WHOOP, before any row
    /// moves. The caller re-targets the live link right after, so new samples land under the canonical
    /// id while older rows are still being folded in, and the strap keeps recording throughout.
    /// Idempotent; `fold` calls it too.
    public static func bind(writer: some DatabaseWriter, identityFrom: String?) throws {
        try writer.write { db in
            // The canonical row exists on every install (migration v15 seeds it), but a user may have
            // forgotten it; recreate it from the identity row so the fold always has a home.
            let hasCanonical = try Bool.fetchOne(db, sql: "SELECT 1 FROM pairedDevice WHERE id = ?",
                                                 arguments: [canonicalId]) ?? false
            if !hasCanonical {
                let template = try identityFrom
                    ?? String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE id LIKE 'whoop-%' ORDER BY addedAt DESC LIMIT 1")
                try db.execute(sql: """
                    INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
                    SELECT ?, brand, model, NULL, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt
                    FROM pairedDevice WHERE id = ?
                    """, arguments: [canonicalId, template])
            }
            if let identityFrom {
                try db.execute(sql: """
                    UPDATE pairedDevice SET
                        peripheralId = (SELECT peripheralId FROM pairedDevice WHERE id = :s),
                        model        = (SELECT model        FROM pairedDevice WHERE id = :s),
                        capabilities = (SELECT capabilities FROM pairedDevice WHERE id = :s),
                        lastSeenAt   = MAX(lastSeenAt, (SELECT lastSeenAt FROM pairedDevice WHERE id = :s))
                    WHERE id = :c AND (SELECT peripheralId FROM pairedDevice WHERE id = :s) IS NOT NULL
                    """, arguments: ["s": identityFrom, "c": canonicalId])
                // Guarded on a non-nil peripheral so a resumed fold, whose identity row was already
                // cleared below, never wipes the canonical row's strap. The extra row must not keep the same strap: two rows on one peripheral make the
                // connect-time id lookup ambiguous while the fold runs.
                try db.execute(sql: "UPDATE pairedDevice SET peripheralId = NULL WHERE id = ?", arguments: [identityFrom])
            }
            // Same rule when a pairing bound the canonical row to a strap an extra row also names.
            try db.execute(sql: """
                UPDATE pairedDevice SET peripheralId = NULL
                WHERE id LIKE 'whoop-%' AND peripheralId = (SELECT peripheralId FROM pairedDevice WHERE id = ?)
                """, arguments: [canonicalId])
            // The WHOOP stays the active source when any WHOOP was; another active source (an Apple
            // Watch) keeps its place and the WHOOP becomes a paired one rather than an archived one.
            let whoopActive = try Bool.fetchOne(db, sql: """
                SELECT 1 FROM pairedDevice WHERE status = 'active' AND (id = ? OR id LIKE 'whoop-%')
                """, arguments: [canonicalId]) ?? false
            if whoopActive {
                try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
                try db.execute(sql: "UPDATE pairedDevice SET status = 'active' WHERE id = ?", arguments: [canonicalId])
            } else {
                try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE id = ? AND status = 'archived'",
                               arguments: [canonicalId])
            }
        }
    }

    /// Move every other WHOOP id onto `canonicalId` and remove the extra registry rows.
    ///
    /// - Parameters:
    ///   - identityFrom: the registry row whose strap identity (peripheral, model, last seen) the canonical
    ///     row takes on, normally the strap that replaced the others. nil keeps the canonical row's own.
    ///   - progress: called after each chunk with the number of rows moved so far.
    /// - Returns: the source ids that were folded.
    @discardableResult
    public static func fold(writer: some DatabaseWriter,
                            identityFrom: String?,
                            chunkSize: Int = defaultChunkSize,
                            progress: ((Int) -> Void)? = nil) throws -> [String] {
        let (sources, tables) = try writer.read { db in (try sourceIds(in: db), try deviceTables(in: db)) }
        guard !sources.isEmpty else { return [] }

        try bind(writer: writer, identityFrom: identityFrom)

        var moved = 0
        for source in sources {
            let pairs = [(source, canonicalId),
                         (source + DeviceRegistryStore.computedSuffix, canonicalId + DeviceRegistryStore.computedSuffix)]
            for (from, to) in pairs {
                for table in tables {
                    while true {
                        let count = try writer.write { db -> Int in
                            let rowids = try Int64.fetchAll(db, sql: "SELECT rowid FROM \(table) WHERE deviceId = ? LIMIT ?",
                                                            arguments: [from, chunkSize])
                            guard !rowids.isEmpty else { return 0 }
                            let list = rowids.map(String.init).joined(separator: ",")
                            try db.execute(sql: "UPDATE OR IGNORE \(table) SET deviceId = ? WHERE rowid IN (\(list))",
                                           arguments: [to])
                            // What the update ignored clashed with a canonical row; the canonical row wins.
                            // `+deviceId` keeps the planner on the rowid list: through the deviceId index it
                            // walked every remaining row of the source per chunk, quadratic on millions.
                            try db.execute(sql: "DELETE FROM \(table) WHERE rowid IN (\(list)) AND +deviceId = ?",
                                           arguments: [from])
                            return rowids.count
                        }
                        guard count > 0 else { break }
                        moved += count
                        progress?(moved)
                    }
                }
            }
        }

        try writer.write { db in
            // Provenance names the source a computed day came from; keep it pointing at a live id.
            for source in sources {
                try db.execute(sql: "UPDATE scoreInputProvenance SET sourceId = ? WHERE sourceId = ?",
                               arguments: [canonicalId, source])
            }
            for id in try String.fetchAll(db, sql: "SELECT id FROM pairedDevice WHERE id LIKE 'whoop-%'") {
                try db.execute(sql: "DELETE FROM pairedDevice WHERE id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [id])
            }
            // Rows now live under a different deviceId, which is what day ownership resolves by.
            try WhoopStore.markAnalysisDeviceChanged(db, deviceId: canonicalId)
        }
        return sources
    }
}
