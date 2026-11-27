package com.noop.core

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.util.concurrent.Executors

/**
 * Tells the shared core whether a NOOP screen is in front (`analysis.background`), so its daily pass follows
 * Apple's background rules (`RescoreBackgroundPolicy`): in the background a pass rests between stretches of work
 * and a post-offload pass starts at most every 30 minutes, and the one put off runs as soon as a screen is back.
 * The core assumes the background until told otherwise, which is right for a process the strap service started.
 */
object CoreForeground : Application.ActivityLifecycleCallbacks {
    /** One thread, so the core hears the changes in the order they happened, off the main thread. */
    private val calls = Executors.newSingleThreadExecutor { r -> Thread(r, "core-foreground").apply { isDaemon = true } }
    private var started = 0

    fun install(app: Application) {
        app.registerActivityLifecycleCallbacks(this)
    }

    override fun onActivityStarted(activity: Activity) {
        if (started++ == 0) report(background = false)
    }

    override fun onActivityStopped(activity: Activity) {
        if (started > 0 && --started == 0) report(background = true)
    }

    private fun report(background: Boolean) {
        if (!SwiftCore.available) return
        calls.execute { runCatching { SwiftCore.call("analysis.background", """{"background":$background}""") } }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityResumed(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}
}
