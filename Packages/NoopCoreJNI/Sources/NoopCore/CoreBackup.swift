import Foundation
import StrandCore
import WhoopStore

/// The `.noopbak` export and import of the core's store for the Android More screen (Android plan E-3e), through
/// the same `BackupArchive` the Apple apps use, so a backup from either platform has one format and one set of
/// checks. Goal settings use the existing Apple `goals.bundle` wire format; other host preferences are
/// not yet included.
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

    /// Writes a consistent SQLite snapshot and derives goal settings from that same snapshot before
    /// archiving and verifying it. Concurrent collection cannot make the two goal readouts disagree.
    public static func export(store: WhoopStore, dbPath: String, to dest: String, scratch: String,
                              appVersion: String, appBuild: String) async -> Result {
        let fm = FileManager.default
        let destURL = URL(fileURLWithPath: dest)
        try? fm.removeItem(at: destURL)
        let snapshotDirectory = URL(fileURLWithPath: scratch, isDirectory: true)
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: snapshotDirectory) }
        do {
            try fm.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            let snapshot = snapshotDirectory.appendingPathComponent(BackupArchive.entryName)
            let goalImage = try await store.writeBackupSnapshot(to: snapshot.path)
            let preferences = try GoalPreferenceImage(serialized: goalImage)
            let settings = GoalBackupBundle.encode(from: preferences).flatMap {
                BackupSettings.encode([GoalBackupBundle.settingsKey: $0])
            }
            try BackupArchive.writeVerified(
                dbURL: snapshot, to: destURL, settingsJSON: settings,
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
            prepareStagedDatabase: { database, settings in
                // Only whitelisted goal values enter the staged source image. A backup without
                // settings keeps its database state, including older plain-SQLite exports.
                let bundle = settings.flatMap { BackupSettings.decode($0)[GoalBackupBundle.settingsKey] as? String }
                try WhoopStore.prepareRestoredGoalPreferenceState(at: database.path, sealAndroidInputs: true) { previous in
                    guard let bundle else { return previous }
                    let image = try GoalPreferenceImage(serialized: previous)
                    guard GoalBackupBundle.apply(bundle, to: image) > 0 else { return previous }
                    return try image.serialized()
                }
            },
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
