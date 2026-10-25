package com.noop.core

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Fork (DX23876), Android plan D-5: the shared Swift core (`Packages/NoopCoreJNI`, built into libNoopCore.so by
 * android/swift-core/build-swift-core.sh). Every call goes to Swift through JNI; the JNI side only converts
 * arguments.
 *
 * The library is in the APK only when the build ran with `-Pnoop.swiftCore=true`, and only for arm64, so
 * [available] says whether it loaded. Until the deep-core wiring replaces the Kotlin data layer, nothing
 * depends on it: [probe] opens the core's own store beside the app's and logs what it found.
 */
object SwiftCore {
    private const val TAG = "SwiftCore"

    /** Whether libNoopCore.so (and the Swift runtime it needs) loaded in this process. */
    val available: Boolean by lazy {
        try {
            System.loadLibrary("NoopCore")
            true
        } catch (e: UnsatisfiedLinkError) {
            Log.i(TAG, "not in this build: ${e.message}")
            false
        }
    }

    /** The analysis recipe the core scores with (`AnalysisRecipe.currentVersion`). */
    external fun recipeVersion(): Int

    /** Opens, creating and migrating as needed, the store at [path]; the migrations applied, or negative. */
    external fun openStore(path: String): Long

    /** Logs the core's recipe and the state of its store. Blocks; call it off the main thread. */
    fun probe(context: Context) {
        if (!available) return
        val store = File(context.filesDir, "core/noop-core.sqlite").apply { parentFile?.mkdirs() }
        val migrations = openStore(store.path)
        Log.i(TAG, "recipe AI-${recipeVersion()}, store migrations $migrations")
    }
}
