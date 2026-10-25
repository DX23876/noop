import Foundation
import StrandCore
import WhoopStore

/// The `.noopbak` export and import of the core's store for the Android More screen (Android plan E-3e), through
/// the same `BackupArchive` the Apple apps use, so a backup from either platform has one format and one set of
/// checks. Settings are not part of an Android backup yet (`settings.json` is left out, as a legacy backup does).
public enum CoreBackup {
    /// How an export or import ended, as one word plus a detail for the screen to translate.
    public enum Result: Equatable, Sendable {
        case done
        /// The import needs the app restarted before the restored store is read.
        case imported
        case tooLarge(String)
        case failed(String)

        public var line: String {
            switch self {
            case .done: return "done"
            case .imported: return "imported"
            case .tooLarge(let name): return "tooLarge:\(name)"
            case .failed(let why): return "failed:\(why)"
            }
        }
    }

    /// Writes the store at `dbPath` to `dest` as a verified `.noopbak`: the WAL is folded into the database
    /// first, then the archive is written and read back (`BackupArchive.writeVerified`).
    public static func export(store: WhoopStore, dbPath: String, to dest: String, scratch: String,
                              appVersion: String, appBuild: String) async -> Result {
        do {
            try await store.checkpointWAL()
        } catch {
            return .failed("checkpoint")
        }
        let fm = FileManager.default
        let destURL = URL(fileURLWithPath: dest)
        try? fm.removeItem(at: destURL)
        do {
            try BackupArchive.writeVerified(
                dbURL: URL(fileURLWithPath: dbPath), to: destURL, settingsJSON: nil,
                manifestJSON: BackupArchive.manifestJSON(appVersion: appVersion, appBuild: appBuild,
                                                         platform: "android"),
                scratchRoot: URL(fileURLWithPath: scratch, isDirectory: true))
            return .done
        } catch BackupArchive.WriteError.integrity(let complaint) {
            return .failed("integrity:\(complaint)")
        } catch BackupArchive.WriteError.incomplete {
            return .failed("incomplete")
        } catch BackupArchive.WriteError.unverified {
            return .failed("unverified")
        } catch {
            return .failed("write:\(error.localizedDescription)")
        }
    }

    /// Restores `source` over the store at `dbPath` (`BackupArchive.restore`: archive and SQLite checks, the
    /// previous store kept beside it, rollback on failure). The caller restarts the app afterwards, since the open
    /// store still reads the file it had before.
    public static func restore(from source: String, toDatabaseAt dbPath: String, scratch: String,
                               allowOversize: Bool = false) -> Result {
        let outcome = BackupArchive.restore(
            from: URL(fileURLWithPath: source), toDatabaseAt: dbPath,
            scratchRoot: URL(fileURLWithPath: scratch, isDirectory: true), allowOversize: allowOversize,
            applySettings: { _ in })
        switch outcome {
        case .imported:
            return .imported
        case .tooLarge(let name):
            return .tooLarge(name)
        case .failure(let failure):
            return .failed(reason(failure))
        }
    }

    private static func reason(_ failure: BackupArchive.RestoreFailure) -> String {
        switch failure {
        case .archiveUnreadable: return "archiveUnreadable"
        case .noDatabaseEntry: return "noDatabaseEntry"
        case .notSQLite: return "notSQLite"
        case .foreignBackup: return "foreignBackup"
        case .damaged: return "damaged"
        case .copyFailedKept: return "copyFailedKept"
        case .postRestoreRolledBack: return "postRestoreRolledBack"
        case .postRestoreRemoved: return "postRestoreRemoved"
        case .importFailed: return "importFailed"
        }
    }
}
