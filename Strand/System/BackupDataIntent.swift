import Foundation
import AppIntents
import UniformTypeIdentifiers

// MARK: - Back up NOOP data through Shortcuts (Discord 2026-11-14)
//
// A backup ran only from Settings or as the folder backup's daily catch-up, so a wearer who wanted one before
// installing a testing build had to make it by hand every time. This hands the SAME `.noopbak` the Settings
// export writes (`DataBackup.writeBackup`, checkpoint first) to Shortcuts, so an automation decides when it runs
// and where the file goes (Files, iCloud Drive, another cloud). NOOP still sends nothing anywhere: the file
// leaves only through the wearer's own automation, as it does through the share sheet.

/// Why a backup from Shortcuts failed, in the words Shortcuts shows for a failed step.
enum BackupIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: return "NOOP could not open its data in time. Open NOOP once and run the shortcut again."
        case .failed(let reason): return "\(reason)"
        }
    }
}

/// Return a complete NOOP backup as a `.noopbak` file, ready for a Shortcuts "Save File" step.
@available(macOS 13.0, *)
struct BackupDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Back Up NOOP Data"
    static let description = IntentDescription(
        "Make a complete backup of your NOOP data as a .noopbak file, the same file Settings exports. Save it anywhere with the next step.")
    /// No screen is needed: the file is written from the store and returned.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        guard let repo = await Self.repository() else { throw BackupIntentError.notRunning }
        // A folder of its own in the temporary directory, emptied first, so repeated runs never pile up
        // 100 MB files the system has to clear later.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NOOP shortcut backup", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = BackupSync.snapshotName(Int(Date().timeIntervalSince1970 * 1000))
        let dest = folder.appendingPathComponent(name)
        switch await DataBackup.writeBackup(checkpoint: { await repo.checkpointForBackup() }, to: dest) {
        case .exported(let url), .exportedOversize(let url, _, _):
            let type = UTType(filenameExtension: "noopbak") ?? .zip
            return .result(value: IntentFile(fileURL: url, filename: name, type: type),
                           dialog: "Backed up your NOOP data.")
        case .failure(let reason):
            throw BackupIntentError.failed(reason)
        default:
            throw BackupIntentError.failed(String(localized: "Backup failed."))
        }
    }

    /// The running app's repository. A cold launch can hand the intent its first tick before the model exists,
    /// so it waits a few seconds for it, as the route export and strap-sync shortcuts do.
    @MainActor
    static func repository(waitSeconds: Int = 5) async -> Repository? {
        for _ in 0..<waitSeconds {
            if let model = AppModel.shared { return model.repo }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return AppModel.shared?.repo
    }
}
