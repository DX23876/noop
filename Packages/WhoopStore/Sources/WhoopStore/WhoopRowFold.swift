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
        let sources = try writer.read { try sourceIds(in: $0) }
        guard !sources.isEmpty else { return [] }
        var moved = 0
        while true {
            let step = try foldStep(writer: writer, identityFrom: identityFrom, chunkSize: chunkSize)
            if step.moved > 0 {
                moved += step.moved
                progress?(moved)
            }
            if step.done { break }
        }
        return sources
    }

    /// What one `foldStep` did.
    public struct Step: Equatable, Sendable {
        /// Rows this step moved. 0 means it found nothing left to move.
        public let moved: Int
        /// True once every source has been folded and retired; the caller stops asking.
        public let done: Bool
        public init(moved: Int, done: Bool) { self.moved = moved; self.done = done }
    }

    /// One chunk of the fold, so a host that cannot take a progress closure can run it and report
    /// between chunks. Android calls this over the JSON bridge (`device.whoopMergeStep`), where a
    /// closure cannot cross; `fold` above is the same work in a loop, so there is one implementation of
    /// the rule and not two. Safe to interrupt between steps, exactly as the whole fold is: every row is
    /// under one id at every moment, and the next step continues.
    public static func foldStep(writer: some DatabaseWriter,
                                identityFrom: String?,
                                chunkSize: Int = defaultChunkSize) throws -> Step {
        let (sources, tables) = try writer.read { db in (try sourceIds(in: db), try deviceTables(in: db)) }
        guard !sources.isEmpty else { return Step(moved: 0, done: true) }
        // Idempotent, and the first thing every step does: the live strap records under the surviving id
        // before any row moves, however many steps the fold takes.
        try bind(writer: writer, identityFrom: identityFrom)
        for source in sources {
            for (from, to) in movePairs(for: source) {
                for table in tables {
                    let moved = try moveChunk(writer: writer, table: table, from: from, to: to, chunkSize: chunkSize)
                    if moved > 0 { return Step(moved: moved, done: false) }
                }
            }
            // This source has nothing left anywhere, so its registry row goes now rather than at the very
            // end: that is what keeps a half-done fold discoverable (`isNeeded`) through the sources that
            // remain, and it never deletes a row whose last sample has not moved.
            try retire(writer: writer, source: source)
        }
        // Rows now live under a different deviceId, which is what day ownership resolves by.
        try writer.write { db in try WhoopStore.markAnalysisDeviceChanged(db, deviceId: canonicalId) }
        return Step(moved: 0, done: true)
    }

    /// A source's own id and its computed sibling, each with the canonical id it moves onto.
    static func movePairs(for source: String) -> [(String, String)] {
        [(source, canonicalId),
         (source + DeviceRegistryStore.computedSuffix, canonicalId + DeviceRegistryStore.computedSuffix)]
    }

    /// Move at most `chunkSize` rows of one table in one transaction; returns how many moved.
    static func moveChunk(writer: some DatabaseWriter, table: String, from: String, to: String,
                          chunkSize: Int) throws -> Int {
        try writer.write { db -> Int in
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
    }

    /// A folded source's last traces: its provenance moves onto the canonical id (provenance names the
    /// source a computed day came from, so it must point at a live id) and its registry rows go.
    static func retire(writer: some DatabaseWriter, source: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE scoreInputProvenance SET sourceId = ? WHERE sourceId = ?",
                           arguments: [canonicalId, source])
            try db.execute(sql: "DELETE FROM pairedDevice WHERE id = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [source])
        }
    }

    /// What the Devices screen needs to make the offer: whether there is anything to fold, and which
    /// strap stays connected.
    public struct Offer: Equatable, Sendable {
        public let needed: Bool
        public let keeperId: String?
        /// The keeper as the screen names it in the confirmation.
        public let keeperName: String?
        /// The row whose strap identity the canonical row takes on, i.e. what `bind` and `fold` want:
        /// nil when the keeper already IS the canonical row.
        public let identityFrom: String?
        public static let none = Offer(needed: false, keeperId: nil, keeperName: nil, identityFrom: nil)
        public init(needed: Bool, keeperId: String?, keeperName: String?, identityFrom: String?) {
            self.needed = needed; self.keeperId = keeperId
            self.keeperName = keeperName; self.identityFrom = identityFrom
        }
    }

    /// The WHOOP whose strap stays connected after folding: the active WHOOP, which is the strap in use;
    /// with none active, the newest extra pairing. Pure, so the Apple app can ask it of the list it
    /// already publishes while `offer` asks it of the store — one rule, never two answers.
    public static func keeper(among devices: [PairedDevice]) -> PairedDevice? {
        let whoops = devices.filter { $0.id == canonicalId || $0.id.hasPrefix("whoop-") }
        return whoops.first(where: { $0.status == .active })
            ?? whoops.filter { $0.id.hasPrefix("whoop-") }.max(by: { $0.addedAt < $1.addedAt })
    }

    /// What `bind`/`fold` take as `identityFrom` for a keeper: nil when the keeper is the canonical row,
    /// which already holds its own strap identity.
    public static func identity(of keeper: PairedDevice?) -> String? {
        keeper?.id == canonicalId ? nil : keeper?.id
    }

    public static func offer(in db: Database) throws -> Offer {
        guard try isNeeded(in: db) else { return .none }
        let keeper = keeper(among: try DeviceRegistryStore.devices(db))
        return Offer(needed: true, keeperId: keeper?.id, keeperName: keeper?.displayName,
                     identityFrom: identity(of: keeper))
    }

    /// Outcome of `takeOver`.
    public struct TakeOver: Equatable, Sendable {
        /// False when there is no canonical row to take over, so the caller registers its own row.
        public let took: Bool
        /// True when the canonical row was ALREADY the active one and now names another strap: no
        /// active-device change fires, so the host has to re-target the live link itself.
        public let needsRetarget: Bool
        public init(took: Bool, needsRetarget: Bool) { self.took = took; self.needsRetarget = needsRetarget }
    }

    /// One WHOOP entry at pairing: a strap that replaces the previous one takes over the canonical row
    /// instead of becoming a second card, so replacing a strap never splits the list or the history.
    /// A strap that does not replace (a second person's strap) is not this path; the caller adds its own
    /// row. Capabilities are deliberately left as they are, as the Apple app leaves them.
    public static func takeOver(writer: some DatabaseWriter, peripheralId: String, model: String,
                                nickname: String?, makeActive: Bool) throws -> TakeOver {
        try writer.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM pairedDevice WHERE id = ?",
                                    arguments: [canonicalId]) ?? false else {
                return TakeOver(took: false, needsRetarget: false)
            }
            // Read before the writes below: they do not touch `status`, but the answer is what decides
            // between a re-target and an active-device change, so it is taken once.
            let wasActive = try Bool.fetchOne(db, sql: "SELECT 1 FROM pairedDevice WHERE id = ? AND status = 'active'",
                                              arguments: [canonicalId]) ?? false
            let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = ?, model = ?, nickname = ? WHERE id = ?",
                           arguments: [peripheralId, model,
                                       (trimmed?.isEmpty == false) ? trimmed : nil, canonicalId])
            guard makeActive, !wasActive else { return TakeOver(took: true, needsRetarget: makeActive && wasActive) }
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
            try db.execute(sql: "UPDATE pairedDevice SET status = 'active', lastSeenAt = ? WHERE id = ?",
                           arguments: [Int(Date().timeIntervalSince1970), canonicalId])
            return TakeOver(took: true, needsRetarget: false)
        }
    }
}
