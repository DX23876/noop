import Foundation
import StrandCore
import WhoopStore

/// The plain Swift side of every Android entry point: no JNI types, so it runs and is tested on any platform.
/// The JNI functions in JNIExports.swift only convert arguments and call these.
public enum Bridge {
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
}
