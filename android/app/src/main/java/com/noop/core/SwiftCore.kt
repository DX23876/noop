package com.noop.core

import android.content.Context
import android.os.Handler
import android.os.Looper
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

    /**
     * Hooks Swift's main queue, and with it every `@MainActor` job in the core, into the calling thread's looper.
     * Must run on Android's main thread; 0 on success, negative when it could not be installed.
     */
    external fun installMainActor(): Int

    /** Queues one job on Swift's main actor; [mainActorProbeRuns] counts the ones that ran. */
    external fun scheduleMainActorProbe()

    external fun mainActorProbeRuns(): Int

    // The shadow session (CoreShadow): frames in, nothing out to the strap.
    external fun shadowStart(path: String, deviceId: String): Int
    external fun shadowFamily(whoop5: Boolean)
    external fun shadowClock(device: Long, wall: Long)
    external fun shadowLiveFrame(frame: ByteArray)
    external fun shadowOffloadBegin(continuedAfterRows: Boolean)
    external fun shadowOffloadFrame(frame: ByteArray)
    external fun shadowFlush()
    external fun shadowResetTally()
    external fun shadowTally(): String?
    external fun shadowAnalyze(age: Int, sex: String, weightKg: Double, heightCm: Double, hrMaxOverride: Int)
    external fun shadowToday(): String?

    // Reads for the screens (CoreRead): JSON, or null; they block until the store answers.
    external fun readDay(day: String): String?
    external fun readNights(from: Long, to: Long): String?
    external fun readSeries(metric: String, from: String, to: String): String?
    /** Demo builds only: writes the demo history into an empty store; the days written. */
    external fun seedDemo(): Int

    /** Whether the last probe job ran on Android's main thread. */
    external fun mainActorProbeOnMainThread(): Boolean

    /**
     * Loads the core and hooks Swift's main actor into Android's main thread, then, off the main thread, logs the
     * core's recipe and the state of its store, and a second later whether a main-actor job ran on the main
     * thread. Must be called on the main thread: libdispatch takes the thread that loads it as its main thread,
     * so loading the library anywhere else would bind @MainActor work to that other thread.
     */
    fun start(context: Context) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "SwiftCore.start must run on the main thread" }
        if (!available) return
        val installed = installMainActor()
        scheduleMainActorProbe()
        val main = Handler(Looper.getMainLooper())
        main.postDelayed({
            Log.i(TAG, "main actor installed=$installed, probe jobs run=${mainActorProbeRuns()}, " +
                "on main thread=${mainActorProbeOnMainThread()}")
        }, 1_000)
        Thread({
            val store = File(context.filesDir, "core/noop-core.sqlite").apply { parentFile?.mkdirs() }
            Log.i(TAG, "recipe AI-${recipeVersion()}, store migrations ${openStore(store.path)}")
        }, "swift-core-probe").start()
    }
}
