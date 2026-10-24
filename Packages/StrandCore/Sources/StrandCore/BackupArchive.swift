import Foundation
import GRDB   // re-exports the SQLite C API on every platform (Apple's SQLite3 module, CSQLite elsewhere)
import WhoopStore
import ZIPFoundation

/// The `.noopbak` file format (moved from the app's `DataBackup`, Android plan B3 step 6): a deflate ZIP with the
/// SQLite store under `noop-backup.sqlite`, an optional `settings.json` and a provenance manifest; the write-time
/// verification; and the hardened restore with its snapshot and rollback. The app keeps the file pickers, the
/// settings it adds and re-applies, and the translated messages.
public enum BackupArchive {
    /// Canonical entry name for the SQLite inside a `.noopbak` ZIP. Matches the Android exporter so
    /// a backup produced on either platform restores on the other.
    public static let entryName = "noop-backup.sqlite"
    /// The largest database a restore extracts without the wearer's go-ahead.
    public static let maxSQLiteBytes: Int64 = 2_147_483_648
    static let maxSettingsBytes: Int64 = 1_048_576

    /// The smallest a real database entry can be: SQLite's own file header is exactly this long, so
    /// anything shorter cannot be a database whatever else it looks like.
    public static let minimumEntryBytes: UInt32 = 100

    /// Whether the `.noopbak` at `url` is a COMPLETE archive carrying a plausible database entry.
    ///
    /// #1014 (write-side): the SOURCE is verified before archiving, but the PRODUCED file can still be
    /// torn by a full disk, a dying filesystem, or a cloud client that drops the tail mid-write, and such
    /// a truncated `.noopbak` otherwise "restores" into an empty store, caught only by the import-side
    /// quick_check much later, when the original may be long gone.
    ///
    /// Opening an `Archive` for reading parses the CENTRAL DIRECTORY, which lives at the end of a ZIP, so
    /// a file cut short does not open at all. That is cheap (an index read, no extraction) and is what
    /// makes this catch truncation rather than merely mis-content.
    ///
    /// Extracted from `writeVerifiedBackupZip` so it can be driven against hand-built archives: this
    /// guard has protected every export since #1014 and, until now, had no test of its own. The Android
    /// twin is `DataBackup.hasEndOfCentralDirectory` plus `backupStreamIsIntact`, which has to find the
    /// end record itself because `ZipInputStream` never looks for one.
    /// What a post-write check concluded about the file just produced.
    ///
    /// `unverifiable` exists so that failing to READ a backup is never mistaken for evidence against it.
    /// The caller DELETES a `torn` file, and deleting on "we could not look" would let a transient read
    /// failure destroy a backup that was perfectly good. Twin of the Android `BackupWriteVerdict`.
    public enum WriteVerdict: Equatable { case intact, torn, unverifiable }

    /// Re-read the `.noopbak` just written to `url` and say what it looks like.
    ///
    /// Unreadable is its own answer rather than a bad one: it says nothing about the CONTENT, and the
    /// caller's response to `torn` is destructive. Past that gate a file that will not open as an
    /// archive really is torn, because opening one only reads the central directory a complete ZIP has.
    public static func verifyWritten(at url: URL) -> WriteVerdict {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .unverifiable }
        guard let written = try? Archive(url: url, accessMode: .read),
              let dbEntry = written.first(where: { ($0.path as NSString).lastPathComponent == entryName }),
              dbEntry.uncompressedSize >= minimumEntryBytes else { return .torn }
        return .intact
    }

    /// Why a verified write failed.
    public enum WriteError: Error, Equatable {
        /// The live database failed its integrity check, so a backup of it would not restore.
        case integrity(complaint: String)
        /// The written file is torn (its database entry is missing or truncated); it was deleted.
        case incomplete
        /// The written file could not be read back to check it; it was left in place.
        case unverified
    }

    /// The production export path: verify the source, archive it, then read the archive back (#1014). Archiving
    /// an already-corrupt database writes a `.noopbak` that only fails the import-side gate months later; a torn
    /// write is deleted rather than left masquerading as a good snapshot; a write that cannot be read back is left
    /// in place, since failing to look is no evidence against it.
    public static func writeVerified(dbURL: URL, to dest: URL, settingsJSON: Data?, manifestJSON: Data,
                                     scratchRoot: URL) throws {
        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
            throw WriteError.integrity(complaint: complaint)
        }
        try writeZip(dbURL: dbURL, to: dest, settingsJSON: settingsJSON, manifestJSON: manifestJSON,
                     scratchRoot: scratchRoot)
        switch verifyWritten(at: dest) {
        case .intact:
            break
        case .torn:
            try? FileManager.default.removeItem(at: dest)
            throw WriteError.incomplete
        case .unverifiable:
            throw WriteError.unverified
        }
    }

    public static func writeZip(dbURL: URL, to dest: URL, settingsJSON: Data?, manifestJSON: Data,
                                scratchRoot: URL) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        try archive.addEntry(with: entryName, fileURL: dbURL, compressionMethod: .deflate)
        let fm = FileManager.default
        // Stage each JSON through a temp file so it uses the exact same file-URL addEntry idiom as the DB
        // entry (one container code path, no provider-API variant to drift).
        if let settingsJSON {
            let tmpJSON = scratchRoot.appendingPathComponent("settings-\(UUID().uuidString).json")
            try settingsJSON.write(to: tmpJSON)
            defer { try? fm.removeItem(at: tmpJSON) }
            try archive.addEntry(with: BackupSettings.entryName, fileURL: tmpJSON, compressionMethod: .deflate)
        }
        // #1410: manifest LAST (after the DB + optional settings) and ALWAYS written — even a legacy
        // nil-settings backup states which build produced it.
        let tmpManifest = scratchRoot.appendingPathComponent("manifest-\(UUID().uuidString).json")
        try manifestJSON.write(to: tmpManifest)
        defer { try? fm.removeItem(at: tmpManifest) }
        try archive.addEntry(with: BackupManifest.entryName, fileURL: tmpManifest, compressionMethod: .deflate)
    }

    /// #1410: the provenance manifest (app version and build, platform, GRDB schema, export time) as JSON.
    public static func manifestJSON(appVersion: String, appBuild: String, platform: String) -> Data {
        let json = BackupManifest.json(appVersion: appVersion, appBuild: appBuild, platform: platform,
                                       schemaVersion: WhoopStoreInfo.schemaVersion,
                                       exportedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        return Data(json.utf8)
    }

    /// How a restore ended.
    public enum RestoreOutcome {
        /// The backup replaced the live database; `sidecar` holds the previous one (or is the database path on a
        /// fresh install, where there was nothing to keep).
        case imported(sidecar: URL)
        /// An entry exceeds the restore limit; the caller may ask the wearer and retry with `allowOversize`.
        case tooLarge(name: String)
        case failure(RestoreFailure)
    }

    /// Why a restore failed. Every case leaves the live database as it was, except where its name says otherwise.
    public enum RestoreFailure: Equatable {
        case archiveUnreadable(String)
        case noDatabaseEntry
        case notSQLite
        /// Not a backup of this platform's store (an Android Room backup or another app's database).
        case foreignBackup
        case damaged(complaint: String)
        /// Copying the backup in failed; the previous data was put back.
        case copyFailedKept(String)
        /// The landed file failed its integrity check and the previous data was rolled back.
        case postRestoreRolledBack(complaint: String)
        /// The landed file failed its integrity check on a fresh install and was removed.
        case postRestoreRemoved(complaint: String)
        case importFailed(String)
    }

    /// The hardened restore core, with the destination database path injected so it is unit-testable
    /// against a throwaway DB (real file I/O, never the user's live store). `applySettings` receives a
    /// `settings.json` entry (#1000) only after the swap landed, so a failed or rolled-back restore never
    /// touches settings; legacy backups without one restore exactly as before.
    public static func restore(from pickedSource: URL, toDatabaseAt dbPath: String, scratchRoot: URL,
                               allowOversize: Bool = false,
                               applySettings: (Data) -> Void) -> RestoreOutcome {
        // If the picked file is a .noopbak ZIP, extract the SQLite entry to a temp dir first.
        // Legacy plain-SQLite files fall straight through. The extracted dir is cleaned up below.
        let fm = FileManager.default
        let source: URL
        let extractedDir: URL?

        if isZipFile(at: pickedSource) {
            let tmpExtract = scratchRoot.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try extractBackupZip(at: pickedSource, into: tmpExtract, allowOversize: allowOversize)
            } catch let err as BackupArchiveError {
                try? fm.removeItem(at: tmpExtract)
                // Reported as its own case, not a generic failure: this one is RECOVERABLE, and the caller
                // is the only layer that can ask the user whether to go ahead. (#1807)
                switch err {
                case .entryTooLarge(let name):
                    return .tooLarge(name: name)
                }
            } catch {
                try? fm.removeItem(at: tmpExtract)
                return .failure(.archiveUnreadable(error.localizedDescription))
            }
            guard let sqliteEntry = (try? fm.contentsOfDirectory(
                at: tmpExtract, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "sqlite" }) else {
                try? fm.removeItem(at: tmpExtract)
                return .failure(.noDatabaseEntry)
            }
            source = sqliteEntry
            extractedDir = tmpExtract
        } else {
            source = pickedSource
            extractedDir = nil
        }
        defer { if let d = extractedDir { try? fm.removeItem(at: d) } }

        // Validate: must be a real SQLite database (magic header "SQLite format 3\0").
        guard isSQLiteFile(at: source) else {
            return .failure(.notSQLite)
        }

        // Reject any backup that isn't a clean GRDB (this-app) backup. The magic check passes for ANY
        // SQLite file, so an Android (Room) backup — or any other SQLite file that happens to carry our
        // table names without our `grdb_migrations` bookkeeping — would otherwise replace the live DB
        // and leave the migrator re-running v1 forever (`table "device" already exists`, #222). A valid
        // NOOP-Mac/iOS backup always carries `grdb_migrations`; reject everything else that holds data.
        let backupTables = sqliteTableNames(at: source)
        let origin = backupOrigin(of: backupTables)
        let holdsData = backupTables.contains("device") || backupTables.contains("hrSample")
        if origin == .android || (origin == .unknown && holdsData) {
            return .failure(.foreignBackup)
        }

        // #1014 defence-in-depth: both gates above read only the FIRST pages of the file — the
        // 16-byte magic and sqlite_master both survive a backup that was truncated mid-upload or
        // torn by a flaky drive/cloud sync, and such a file then "restores" into a store that
        // silently shows no data (the #1014 report; the #1000 settings code was exonerated, the
        // family needed armour). Run SQLite's own `PRAGMA quick_check` over the STAGED file,
        // read-only, BEFORE anything touches the live database, and refuse the swap honestly.
        // One carve-out: a legacy plain-SQLite file still travelling with its -wal/-shm siblings
        // (an uncheckpointed manual copy) skips THIS gate — a read-only probe can't recover someone
        // else's WAL (shm rebuild needs write access) and would refuse spuriously. Those rare files
        // are still verified by the post-swap check below, which runs on the landed main file
        // BEFORE the sidecars are laid down and rolls back automatically on failure.
        let legacySidecarsPresent = extractedDir == nil
            && (fm.fileExists(atPath: source.path + "-wal") || fm.fileExists(atPath: source.path + "-shm"))
        if !legacySidecarsPresent,
           let complaint = DatabaseIntegrity.quickCheckFailure(atPath: source.path) {
            return .failure(.damaged(complaint: complaint))
        }

        let dbURL = URL(fileURLWithPath: dbPath)

        do {
            // Snapshot the current DB (+ sidecars) to a timestamped side file so the user can roll back.
            var sidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoop-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                if fm.fileExists(atPath: sidecar.path) { try fm.removeItem(at: sidecar) }
                try fm.copyItem(at: dbURL, to: sidecar)
            } else {
                // Nothing to preserve (fresh install); report a placeholder so the message reads sensibly.
                sidecar = dbURL
            }

            // Remove the live DB and its WAL/SHM siblings, then drop the backup in.
            removeIfPresent(dbURL)
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))

            do {
                try fm.copyItem(at: source, to: dbURL)
            } catch {
                // The live DB was just removed and the replacement didn't land. Roll back to the
                // snapshot so a failed import leaves the user's data exactly as it was, instead of a
                // fresh-empty DB on relaunch (mirrors the Android rollback). Clear any partial-copy
                // leftover first — copyItem fails if the destination exists, which would otherwise
                // block the restore.
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    removeIfPresent(dbURL)
                    try? fm.copyItem(at: sidecar, to: dbURL)
                }
                return .failure(.copyFailedKept(error.localizedDescription))
            }

            // #1014 defence-in-depth, post-swap: re-verify the file that actually LANDED at the
            // live path with a second read-only quick_check. The staged file was verified above,
            // but the copy itself can tear — disk-full mid-copy, a dying filesystem, the device
            // sleeping — and the next launch would meet a corrupt store. Runs BEFORE any legacy
            // sidecars are laid down: a bare main file is always read-only verifiable, and WAL
            // frames carry their own checksums (SQLite validates them on the first real open), so
            // the sidecars don't need this gate. On failure, roll back to the snapshot
            // AUTOMATICALLY and say so; the snapshot file is kept either way (same policy as a
            // successful import: the user can always reach the pre-import bytes).
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
                removeIfPresent(dbURL)
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    try? fm.copyItem(at: sidecar, to: dbURL)
                    return .failure(.postRestoreRolledBack(complaint: complaint))
                }
                // Fresh install: there was no previous store to preserve, so removing the damaged
                // file (done above) restores the exact pre-import state — an empty slate.
                return .failure(.postRestoreRemoved(complaint: complaint))
            }

            // Restore sidecars only for legacy plain-SQLite backups whose WAL wasn't
            // checkpointed at export. ZIP imports are always checkpointed; no sidecars expected.
            // Deliberately AFTER the post-swap integrity check (see above) — this is best-effort
            // (`try?` inside) and can't throw, so the rollback semantics are unchanged.
            if extractedDir == nil {
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-wal")
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-shm")
            }

            // #1000: re-apply the backup's whitelisted profile/display settings (weight, height, age,
            // sex, HR-max override, unit prefs) — but only NOW, after the DB swap landed. A failed or
            // rolled-back restore returns above and never touches settings. Legacy single-entry ZIPs
            // and plain-SQLite backups have no `settings.json` (extractedDir nil / entry absent) and
            // restore exactly as before — no settings, no error. A malformed settings entry degrades
            // to "fewer keys applied" inside BackupSettings.decode; it can never fail the restore.
            if let extractedDir {
                let settingsURL = extractedDir.appendingPathComponent(BackupSettings.entryName)
                if let data = try? Data(contentsOf: settingsURL) { applySettings(data) }
            }
            return .imported(sidecar: sidecar)
        } catch {
            return .failure(.importFailed(error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private enum BackupArchiveError: LocalizedError {
        case entryTooLarge(String)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let name):
                return "\(name) is too large to restore safely."
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Which platform produced a NOOP backup, judged by its migrator's bookkeeping table.
    public enum BackupOrigin: Equatable { case mac, android, unknown }

    /// Pure classification over a backup's `sqlite_master` table names: GRDB (this app) writes
    /// `grdb_migrations`, Room (the Android app) writes `room_master_table`. `.unknown` (neither —
    /// an empty or pre-migration file) falls through to the normal import path, where the
    /// open-time migrator decides. Mirrors the Android `DataBackup.backupOriginOf`.
    public static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        // This platform's marker wins on the (degenerate) both-present case: restoring here is the
        // less destructive read.
        if tableNames.contains("grdb_migrations") { return .mac }
        if tableNames.contains("room_master_table") { return .android }
        // Older Room layouts didn't carry `room_master_table`; treat the Room/AndroidX duo of
        // `android_metadata` + an internal `sqlite_sequence` as an Android backup too.
        if tableNames.contains("android_metadata") && tableNames.contains("sqlite_sequence") {
            return .android
        }
        return .unknown
    }

    /// Every table name in a SQLite file, opened READ-ONLY through the system SQLite so the probed
    /// file is never mutated. Returns an empty set on any failure — the caller treats that as
    /// `.unknown` and falls through to the existing behaviour.
    private static func sqliteTableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: c))
            }
        }
        return names
    }

    /// Read the first 4 bytes and check for the ZIP PK magic (`PK\x03\x04`).
    private static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    /// Extract only the canonical entries from a `.noopbak` ZIP at `zipURL` into `destDir`.
    /// Unknown files are ignored, and each accepted entry is streamed through an uncompressed-size cap
    /// before it lands on disk.
    private static func extractBackupZip(at zipURL: URL, into destDir: URL,
                                         allowOversize: Bool = false) throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent
            let limit: Int64
            switch name {
            case entryName:
                limit = allowOversize ? Int64.max : maxSQLiteBytes
            case BackupSettings.entryName:
                limit = maxSettingsBytes
            default:
                continue
            }
            let out = destDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            var written: Int64 = 0
            _ = try archive.extract(entry) { data in
                let next = written + Int64(data.count)
                guard next <= limit else {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: out)
                    throw BackupArchiveError.entryTooLarge(name)
                }
                try handle.write(contentsOf: data)
                written = next
            }
        }
    }

    /// Read the first 16 bytes and check for the SQLite magic header.
    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        // "SQLite format 3" + NUL terminator.
        let magic: [UInt8] = Array("SQLite format 3".utf8) + [0x00]
        return Array(head) == magic
    }

    private static func removeIfPresent(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    /// Copy a legacy backup's `<source><suffix>` sidecar next to the live DB if it exists, so an
    /// old plain-SQLite backup whose WAL wasn't checkpointed at export restores its committed pages
    /// (SQLite folds them in on open). Not called for ZIP imports (those are always checkpointed).
    private static func restoreSidecar(from source: URL, toMainPath dbPath: String, suffix: String) {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: source.path + suffix)
        guard fm.fileExists(atPath: src.path) else { return }
        let dst = URL(fileURLWithPath: dbPath + suffix)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try? fm.copyItem(at: src, to: dst)
    }
}
