import Foundation
import StrandCore
import WhoopStore

/// The plain Swift side of every Android entry point: no JNI types, so it runs and is tested on any platform.
/// The JNI functions in JNIExports.swift only convert arguments and call these.
public enum Bridge {
    /// How many main-actor jobs `scheduleMainActorProbe` has seen run: the proof that @MainActor work runs on the
    /// platform's main thread (on Android only after the main-queue drain is installed).
    public static var mainActorProbeRuns: Int32 {
        probeLock.lock(); defer { probeLock.unlock() }
        return probeRuns
    }

    /// Queues one job on the main actor; when it runs it counts itself in `mainActorProbeRuns`.
    public static func scheduleMainActorProbe() {
        Task { @MainActor in
            let onMain = Thread.isMainThread
            probeLock.lock(); probeRuns += 1; probeOnMainThread = onMain; probeLock.unlock()
        }
    }

    /// Whether the last probe job ran on the platform's main thread.
    public static var mainActorProbeOnMainThread: Bool {
        probeLock.lock(); defer { probeLock.unlock() }
        return probeOnMainThread
    }

    nonisolated(unsafe) private static var probeOnMainThread = false
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probeRuns: Int32 = 0

    /// The analysis recipe this build of the core scores with (`AnalysisRecipe.currentVersion`).
    public static func recipeVersion() -> Int32 {
        Int32(AnalysisRecipe.currentVersion)
    }

    /// Opens, creating and migrating as needed, the store at `path`, and returns how many migrations it has
    /// applied in total; a negative value when it cannot be opened. Blocks the calling thread, which on
    /// Android is a background thread the caller chose.
    public static func openStore(path: String) -> Int64 {
        final class Box: @unchecked Sendable { var value: Int64 = -1 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let store = try await WhoopStore(path: path)
                box.value = Int64(try await store.appliedMigrationCount())
            } catch {
                box.value = -2
            }
            done.signal()
        }
        done.wait()
        return box.value
    }

    // MARK: - Reads for the screens (CoreRead), as JSON; nil when no session runs or nothing is stored.

    public static func readDay(_ day: String) -> String? {
        blocking { reader in await CoreRead.day(day, reader: reader).map(CoreRead.json) }
    }

    public static func readNights(from: Int, to: Int) -> String? {
        blocking { reader in CoreRead.json(await CoreRead.nights(from: from, to: to, reader: reader)) }
    }

    public static func readSeries(_ metric: String, from: String, to: String) -> String? {
        guard let m = CoreRead.Metric(rawValue: metric) else { return nil }
        return blocking { reader in CoreRead.json(await CoreRead.series(m, from: from, to: to, reader: reader)) }
    }

    // MARK: - Backups (CoreBackup), as one result line: "done", "imported", "tooLarge:<entry>" or "failed:<why>".

    public static func exportBackup(to dest: String, scratch: String, appVersion: String, appBuild: String) -> String {
        guard let (store, path) = ShadowSession.storeAndPath else { return CoreBackup.Result.failed("noSession").line }
        final class Box: @unchecked Sendable { var value = CoreBackup.Result.failed("timeout") }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await CoreBackup.export(store: store, dbPath: path, to: dest, scratch: scratch,
                                                appVersion: appVersion, appBuild: appBuild)
            done.signal()
        }
        done.wait()
        return box.value.line
    }

    /// Restores over the session's store file; the app must restart before it reads the restored data.
    public static func importBackup(from source: String, scratch: String, allowOversize: Bool) -> String {
        guard let (_, path) = ShadowSession.storeAndPath else { return CoreBackup.Result.failed("noSession").line }
        return CoreBackup.restore(from: source, toDatabaseAt: path, scratch: scratch, allowOversize: allowOversize).line
    }

    /// Demo builds only: writes the demo history into the session's store when it has no scored day; the days
    /// written, 0 when it already had some, negative when no session runs or the write failed.
    public static func seedDemo() -> Int32 {
        guard let reader = ShadowSession.reader else { return -1 }
        final class Box: @unchecked Sendable { var value: Int32 = -2 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let n = try? await CoreDemo.seedIfEmpty(store: reader.store, deviceId: reader.activeDeviceId) {
                box.value = Int32(n)
            }
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// Runs one read against the shadow session's store and waits for it; for JNI callers on a background thread.
    private static func blocking(_ read: @escaping @Sendable (StoreReader) async -> String?) -> String? {
        guard let reader = ShadowSession.reader else { return nil }
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await read(reader)
            done.signal()
        }
        done.wait()
        return box.value
    }
}
