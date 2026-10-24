import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import WhoopStore
import StrandCore
import ZIPFoundation

/// Full-database EXPORT / IMPORT for device migration.
///
/// NOOP keeps everything in one SQLite file (`<AppSupport>/OpenWhoop/whoop.sqlite`, plus the
/// `-wal`/`-shm` WAL sidecars while the store is open). Export checkpoints the WAL (so the
/// single file is whole), then wraps the SQLite in a ZIP written as `.noopbak`, alongside a
/// small `settings.json` entry (#1000) carrying the whitelisted profile/display settings (see
/// `BackupSettings`) so a restore also brings back weight/height/units, not just the rows.
/// ZIP deflate typically cuts a 100 MB+ SQLite backup to 10–20 MB. The format is a standard
/// ZIP — users can rename `.noopbak` → `.zip` and extract the SQLite manually on any OS.
///
/// Import detects the format by magic bytes: ZIP (`PK\x03\x04`) or legacy plain SQLite. ZIP
/// backups are extracted to a temp dir, validated, then swapped in exactly like a plain import.
/// Old `.sqlite` / `.noopdb` backups keep working.
///
/// Sandbox-safe: relies on the `com.apple.security.files.user-selected.read-write` entitlement and
/// security-scoped access on the panel-returned URLs. Every path is best-effort — failures surface
/// as a `.failure` result and never crash.
enum DataBackup {
    /// Uncompressed ceiling for the SQLite entry, enforced while EXTRACTING (see `extractBackupZip`).
    /// Deliberately measured on the decompressed stream: this is a zip-bomb guard, and a zip bomb is by
    /// definition small compressed and enormous expanded, so a cap on the archive's own size would be
    /// trivially defeated. Compressing harder cannot help a user past it — the backup is already
    /// `.deflate`d and the count is of bytes landing on disk. (#1807)
    static let maxBackupSQLiteBytes = BackupArchive.maxSQLiteBytes

    // MARK: - Result

    enum BackupResult {
        /// Export wrote the backup to `url`.
        case exported(URL)
        /// Export wrote the backup, but the database is larger than [maxBackupSQLiteBytes], the ceiling
        /// the restore path enforces. The file is valid and worth keeping — restoring it just needs the
        /// user to confirm once. Reported at EXPORT time because the alternative is finding out during a
        /// restore, which is exactly when the original is gone. (#1807)
        case exportedOversize(URL, bytes: Int64, limit: Int64)
        /// Import succeeded; a relaunch is required for it to take effect. `sidecar` is where the
        /// previous database was preserved, in case the user wants to roll back.
        case imported(sidecar: URL)
        /// The user dismissed the save/open panel — nothing happened, show nothing loud.
        case cancelled
        /// The restore stopped ONLY because an entry exceeds the size ceiling. Distinct from `failure`
        /// so the caller can offer to go ahead anyway: the cap is a decompression guard against a hostile
        /// archive, and a backup the user just picked out of their own files is a different threat model
        /// than the one it defends against. (#1807)
        case restoreTooLarge(name: String, limit: Int64)
        /// Something went wrong; `message` is user-facing.
        case failure(String)
    }

    // MARK: - Export

    /// Checkpoint the store and write the live database as a compressed `.noopbak` (single-entry
    /// ZIP) to a user-chosen file.
    ///
    /// - Parameter checkpoint: invoked first to flush the WAL into the main file. Pass
    ///   `repo.checkpointForBackup`. Must succeed — a failed checkpoint means committed pages still
    ///   live in the WAL and would be silently absent from the ZIP; we fail loudly rather than ship
    ///   a partial backup.
    @MainActor
    static func runExport(checkpoint: @escaping () async -> Bool) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet. Import or record some first."))
        }

        // Flush the WAL so the single .sqlite carries everything. Required for ZIP (no sidecar
        // fallback in a single-file archive).
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely export right now. Recent changes are still in the database's write-ahead log. Close any in-flight sync, then try again."))
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = String(localized: "Export NOOP backup")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultBackupName()
        panel.allowedContentTypes = backupContentTypes()
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }

        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        do {
            // NSSavePanel already handled the "replace existing?" confirmation; clear the target.
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            // Reading the whole SQLite and DEFLATE-compressing it is multi-second on a big library
            // (and #1014 added a quick_check read of the whole file first); run it off the main
            // actor so the UI never beach-balls. Only file paths cross the hop.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            }.value
            return exportOutcome(dest, dbURL: dbURL)
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        #else
        let fm = FileManager.default

        // Stage the compressed backup in temp, then hand it to the share sheet.
        let staged = fm.temporaryDirectory.appendingPathComponent(defaultBackupName())
        do {
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            // Off the main actor: same reason as the macOS branch (heavy read + DEFLATE). Only paths hop.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: staged, settingsJSON: currentSettingsJSON())
            }.value
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
        return exportOutcome(dest, dbURL: dbURL)
        #endif
    }

    /// #1014 defence-in-depth (export side): the export's failure when the LIVE database itself is
    /// damaged. Thrown by `writeVerifiedBackupZip`; `LocalizedError` so the existing
    /// "Export failed: \(error.localizedDescription)" surfaces the specific, honest message.
    private struct ExportIntegrityFailure: LocalizedError {
        let complaint: String
        var errorDescription: String? {
            String(localized: "the NOOP database failed its integrity check (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). A backup of it would not restore. Export the WHOOP-format CSV (Settings → Export data) to save what's still readable.")
        }
    }

    /// The freshly-written `.noopbak` failed a post-write structural check — its DB entry is missing or
    /// truncated, i.e. a torn write from a full disk / dying filesystem / flaky cloud sync mid-write.
    /// Thrown by `writeVerifiedBackupZip` so a bad backup fails at WRITE time, not silently — the old
    /// behaviour let a truncated file sit as a "successful" snapshot and only surface at restore (#1014).
    private struct BackupWriteIncomplete: LocalizedError {
        var errorDescription: String? {
            String(localized: "the backup file was written incompletely (its database entry is missing or truncated). Free up space or check the backup folder, then try again.")
        }
    }

    /// Thrown when the written backup could not be READ BACK to check it, which is not the same thing as
    /// finding it damaged and must not be reported as though it were. The file is left where it is.
    private struct BackupWriteUnverified: LocalizedError {
        var errorDescription: String? {
            String(localized: "the backup file was written, but couldn't be read back to check it, so it has been left in place rather than deleted. Open it before you rely on it, or export again somewhere else.")
        }
    }

    /// The production export path: verify, then archive. GRDB checkpoints the WAL first (the
    /// callers' `checkpoint()` guard), so at this point the single file IS the whole store — run a
    /// read-only `PRAGMA quick_check` over it BEFORE zipping (#1014). Archiving an already-corrupt
    /// database writes a `.noopbak` that only fails the import-side integrity gate months later,
    /// when the original data may be long gone; failing loudly NOW is the honest move. The read-only
    /// probe sits safely beside the app's open GRDB pool (WAL allows concurrent readers).
    /// `writeBackupForTesting` deliberately bypasses this so tests can build damaged containers.
    /// `.exported`, or `.exportedOversize` when the database is past the ceiling the restore path
    /// enforces. Measured on the DATABASE, not the finished archive: the archive is `.deflate`d and the
    /// cap the restore checks counts the DECOMPRESSED stream, so the zip's own size says nothing about
    /// whether it can be read back. (#1807)
    private static func exportOutcome(_ dest: URL, dbURL: URL) -> BackupResult {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dbURL.path)
        guard let bytes = (attrs?[.size] as? NSNumber)?.int64Value,
              bytes > maxBackupSQLiteBytes else { return .exported(dest) }
        return .exportedOversize(dest, bytes: bytes, limit: maxBackupSQLiteBytes)
    }

    /// The smallest a real database entry can be (`BackupArchive`).
    static let minimumBackupEntryBytes = BackupArchive.minimumEntryBytes

    /// What a post-write check concluded about the file just produced (`BackupArchive.WriteVerdict`).
    typealias BackupWriteVerdict = BackupArchive.WriteVerdict

    /// Re-read the `.noopbak` just written to `url` and say what it looks like (`BackupArchive`).
    static func verifyWrittenBackup(at url: URL) -> BackupWriteVerdict {
        BackupArchive.verifyWritten(at: url)
    }

    /// Convenience over `verifyWrittenBackup(at:)` for callers that only care whether it passed.
    static func writtenBackupIsIntact(at url: URL) -> Bool {
        verifyWrittenBackup(at: url) == .intact
    }

    private static func writeVerifiedBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?) throws {
        do {
            try BackupArchive.writeVerified(dbURL: dbURL, to: dest, settingsJSON: settingsJSON,
                                            manifestJSON: currentManifestJSON(), scratchRoot: NoopScratch.directory())
        } catch let error as BackupArchive.WriteError {
            switch error {
            case .integrity(let complaint): throw ExportIntegrityFailure(complaint: complaint)
            case .incomplete: throw BackupWriteIncomplete()
            case .unverified: throw BackupWriteUnverified()
            }
        }
    }

    /// Write the live SQLite at `dbURL` into a fresh deflate ZIP at `dest`: the DB under the canonical
    /// entry name `noop-backup.sqlite`, plus (#1000) an optional second entry `settings.json` carrying
    /// the whitelisted profile/display settings, so a restore brings back weight/height/units and not
    /// just the rows. Entry names, entry ORDER (DB first — older importers stop at the first `.sqlite`
    /// entry) and deflate compression match the Android exporter byte-for-byte at the container level,
    /// so a `.noopbak` produced on either platform imports on the other. `settingsJSON == nil` writes
    /// the legacy single-entry ZIP. Mirrors the `Archive` idiom in `WhoopCsvExporter`.
    /// #1410: this build's provenance manifest (Bundle version/build + GRDB schema + export time) as JSON.
    private static func currentManifestJSON() -> Data {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return BackupArchive.manifestJSON(appVersion: version, appBuild: build, platform: "apple")
    }

    private static func writeBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?, manifestJSON: Data) throws {
        try BackupArchive.writeZip(dbURL: dbURL, to: dest, settingsJSON: settingsJSON, manifestJSON: manifestJSON,
                                   scratchRoot: NoopScratch.directory())
    }

    /// This device's whitelisted profile/display settings (see `BackupSettings.whitelist`) as the
    /// `settings.json` payload, or nil when nothing whitelisted was ever set (a fresh install then
    /// exports a legacy DB-only ZIP, which is the right degrade). UserDefaults is thread-safe, so
    /// the detached export tasks may call this off the main actor.
    private static func currentSettingsJSON() -> Data? {
        var values = BackupSettings.snapshot(from: .standard)
        // #1361: bridge the user's custom journal BEHAVIOURS into the whitelisted `journal.customBehaviors`
        // as a newline-joined name list (byte-identical to Android's `noop.journalCustomQuestions`). The
        // journal EFFECTS ride the DB backup, but the DEFINITIONS live only here. `JournalCatalogStore`
        // is @MainActor and this may run off it, so decode the items blob directly and take the custom
        // canonicals. Skipped when there are none.
        if let blob = UserDefaults.standard.data(forKey: JournalCatalogBackupKeys.items),
           let items = try? JSONDecoder().decode([JournalCatalogItem].self, from: blob) {
            let customs = items.filter(\.custom).map(\.canonical)
            if !customs.isEmpty { values["journal.customBehaviors"] = customs.joined(separator: "\n") }
        }
        // Every goal, daily goal, attribution, frozen period result and goal preference, as one string.
        if let goals = GoalBackupBundle.encode(from: .standard) {
            values[GoalBackupBundle.settingsKey] = goals
        }
        return BackupSettings.encode(values)
    }

    /// (Backup & Sync) Write a `.noopbak` to a SPECIFIC `dest` URL with NO save panel: the folder /
    /// auto-backup path. Checkpoints the WAL (so the single `.sqlite` is whole) then writes the same
    /// deflate ZIP via the same `writeBackupZip` the interactive export uses, so folder / auto backups
    /// are byte-identical to a manual export. The CALLER owns any security-scoped access to `dest`
    /// (start/stop around this call). Never presents UI, so it is safe off the main actor.
    static func writeBackup(checkpoint: @escaping () async -> Bool, to dest: URL) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet."))
        }
        // Flush the WAL into the single file (same requirement as the interactive export: a single-file
        // ZIP has no sidecar fallback, so committed pages still in the WAL would otherwise be absent).
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely back up right now. Recent changes are still in the write-ahead log."))
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            return exportOutcome(dest, dbURL: dbURL)
        } catch {
            return .failure(String(localized: "Backup failed: \(error.localizedDescription)"))
        }
    }

    /// Test seam: write a `.noopbak` for an EXPLICIT source database (no checkpoint, no `StorePaths`),
    /// so a unit test can round-trip a throwaway SQLite through the exact ZIP container the app writes.
    /// `settings` (canonical `BackupSettings` keys) adds the `settings.json` entry; nil writes the
    /// legacy single-entry ZIP — tests cover both shapes. Not used by app code; production goes
    /// through `writeBackup(checkpoint:to:)`.
    static func writeBackupForTesting(databaseAt dbURL: URL, to dest: URL,
                                      settings: [String: Any]? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try writeBackupZip(dbURL: dbURL, to: dest,
                           settingsJSON: settings.flatMap { BackupSettings.encode($0) },
                           manifestJSON: currentManifestJSON())
    }

    // MARK: - Import

    /// Pick a `.noopbak` (ZIP) or legacy `.sqlite` backup, validate it, snapshot the current DB
    /// to a side file, then copy the backup over the live database path (removing the `-wal`/`-shm`
    /// siblings). The store stays open, so the swapped-in file only takes effect after a relaunch —
    /// the caller informs the user.
    @MainActor
    static func runImport(allowOversize: Bool = false) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import NOOP backup")
        panel.prompt = String(localized: "Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = backupContentTypes()

        guard panel.runModal() == .OK, let pickedSource = panel.url else { return .cancelled }

        let scoped = pickedSource.startAccessingSecurityScopedResource()
        defer { if scoped { pickedSource.stopAccessingSecurityScopedResource() } }
        #else
        // iOS: pick the backup through the system document picker (asCopy gives us a readable local
        // copy in our temp dir, so no security-scoped bookkeeping is needed).
        guard let pickedSource = await DocumentPicker.importFile(backupContentTypes()) else { return .cancelled }
        #endif

        // Hand the chosen file to the same hardened restore core the folder (Backup & Sync) path uses,
        // so the unzip / magic-byte / GRDB-origin / sidecar-snapshot / rollback logic lives in one place.
        // The restore does heavy synchronous file work (unzip, copy the whole DB, scan sqlite_master,
        // snapshot + rollback), which can run tens of seconds on a big library. Push it off the main
        // actor so the picker's UI thread stays live; the security-scoped access opened above (macOS)
        // stays valid because the surrounding function is still awaiting here. Only Sendable value
        // types (URL, String) cross the hop; the result hops back to main for handleBackup.
        return await Task.detached(priority: .utility) {
            restore(from: pickedSource, toDatabaseAt: dbPath, allowOversize: allowOversize)
        }.value
    }

    /// Restore a chosen backup file directly, with NO picker. The Backup & Sync folder flow calls this
    /// with a snapshot it already resolved from the user's backup folder (the caller owns any
    /// security-scoped access around the call). Runs against the live database path.
    ///
    /// Reuses the exact same hardened path as the picker import: ZIP extraction, SQLite magic-byte
    /// validation, GRDB-origin rejection (a foreign-but-valid SQLite is refused), a timestamped
    /// sidecar snapshot of the current store, and rollback-on-failure so a failed restore leaves the
    /// live database untouched.
    static func restore(from pickedSource: URL) -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        return restore(from: pickedSource, toDatabaseAt: dbPath)
    }

    /// The hardened restore core (`BackupArchive.restore`), with the destination database path injected so it is
    /// unit-testable against a throwaway DB. `settingsDefaults` is where a `settings.json` entry (#1000) is
    /// re-applied — injected for the same reason as `dbPath` (tests use a suite-scoped UserDefaults, never the
    /// runner's real domain).
    static func restore(from pickedSource: URL, toDatabaseAt dbPath: String,
                        settingsDefaults: UserDefaults = .standard,
                        allowOversize: Bool = false) -> BackupResult {
        let outcome = BackupArchive.restore(
            from: pickedSource, toDatabaseAt: dbPath, scratchRoot: NoopScratch.directory(),
            allowOversize: allowOversize,
            applySettings: { applyRestoredSettings($0, to: settingsDefaults) })
        switch outcome {
        case .imported(let sidecar):
            // #57 debug: record when a restore swapped the DB, so the export can correlate a restore with a
            // later write stall (a restore not followed by a relaunch is the #57 failure).
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.lastRestoreAt")
            return .imported(sidecar: sidecar)
        case .tooLarge(let name):
            return .restoreTooLarge(name: name, limit: maxBackupSQLiteBytes)
        case .failure(let failure):
            return .failure(restoreFailureText(failure))
        }
    }

    /// The wearer-facing text of a restore failure (`BackupArchive.RestoreFailure`).
    static func restoreFailureText(_ failure: BackupArchive.RestoreFailure) -> String {
        switch failure {
        case .archiveUnreadable(let detail):
            return String(localized: "Couldn't open the backup archive: \(detail)")
        case .noDatabaseEntry:
            return String(localized: "The backup archive doesn't contain a database file.")
        case .notSQLite:
            return String(localized: "That file isn't a NOOP backup. It doesn't look like a SQLite database.")
        case .foreignBackup:
            return String(localized: "This isn't a NOOP backup from this app. It's missing the migration bookkeeping a NOOP backup carries (it looks like an Android backup or another app's database), and restoring it would strand your store. To move your history across platforms, export the WHOOP-format CSV on the other device (Settings → Export data) and import that here, or import your original WHOOP / Apple Health export.")
        case .damaged(let complaint):
            return String(localized: "This backup file is damaged and can't be restored (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). Your current data was left untouched. Try an earlier backup file.")
        case .copyFailedKept(let detail):
            return String(localized: "Import failed. Your existing data was kept. \(detail)")
        case .postRestoreRolledBack(let complaint):
            return String(localized: "Import failed its post-restore integrity check (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). Your previous data was rolled back automatically and is unchanged.")
        case .postRestoreRemoved(let complaint):
            return String(localized: "Import failed its post-restore integrity check (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). The damaged file was removed; there was no previous data to roll back.")
        case .importFailed(let detail):
            return String(localized: "Import failed: \(detail)")
        }
    }

    /// #1000: re-apply a backup's whitelisted profile/display settings (weight, height, age, sex, HR-max
    /// override, unit prefs) once the swap landed. A malformed entry degrades to "fewer keys applied" inside
    /// `BackupSettings.decode`; it can never fail the restore.
    private static func applyRestoredSettings(_ data: Data, to settingsDefaults: UserDefaults) {
        let decoded = BackupSettings.decode(data)
        BackupSettings.apply(decoded, to: settingsDefaults)
        // #1361: restore custom journal behaviours. `JournalCatalogStore` is @MainActor and
        // this runs off it, so write the restored names to the legacy `journal.customQuestions`
        // array, clear any stale hidden list, and drop the v2 items blob — on the relaunch a
        // restore forces, the store's init migrates those names into fresh v2 items (the same
        // path a pre-v2 install takes). Only when the backup carried them.
        if let joined = decoded["journal.customBehaviors"] as? String {
            let names = joined.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            settingsDefaults.set(names, forKey: JournalCatalogBackupKeys.legacyCustom)
            settingsDefaults.set([String](), forKey: JournalCatalogBackupKeys.legacyHidden)
            settingsDefaults.removeObject(forKey: JournalCatalogBackupKeys.items)
        }
        // The goals system. The stores read their keys at launch, and a restore forces a
        // relaunch, so writing the values back is enough.
        if let goals = decoded[GoalBackupBundle.settingsKey] as? String {
            GoalBackupBundle.apply(goals, to: settingsDefaults)
        }
    }

    // MARK: - Helpers

    /// "NOOP-backup-2026-06-07.noopbak"
    private static func defaultBackupName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "NOOP-backup-\(f.string(from: Date())).noopbak"
    }

    /// Content types accepted by the export/import panels. Includes the new `.noopbak` (ZIP),
    /// generic ZIP, and legacy `.sqlite` / `.database` types so older backups keep working.
    private static func backupContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let noopbak = UTType(filenameExtension: "noopbak") { types.append(noopbak) }
        types.append(.zip)
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        types.append(.database)
        types.append(.data)
        return types
    }

    /// Which platform produced a NOOP backup (`BackupArchive.BackupOrigin`).
    typealias BackupOrigin = BackupArchive.BackupOrigin

    /// Classification over a backup's table names (`BackupArchive.backupOrigin`).
    static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        BackupArchive.backupOrigin(of: tableNames)
    }

}
