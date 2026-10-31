package com.noop.ui.forge

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The rest timer's notification follows the vibration setting after a change (a channel keeps the vibration it was
 * created with), and a running rest survives an activity recreation with its alarm.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE, application = android.app.Application::class)
class RestTimerTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val manager get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @Test fun eachSoundAndVibrationCombinationHasItsOwnChannel() {
        val ids = listOf(true, false).flatMap { s -> listOf(true, false).map { h -> RestNotification.channelId(s, h) } }
        assertEquals(4, ids.toSet().size)
        RestNotification.LEGACY_CHANNEL_IDS.forEach { assertFalse(it in ids) }
    }

    @Test fun aHapticsChangeReachesTheNextNotification() {
        // A channel made before the split, with vibration on.
        manager.createNotificationChannel(NotificationChannel("training_rest", "Rest", NotificationManager.IMPORTANCE_HIGH)
            .apply { enableVibration(true) })
        val on = RestNotification.ensureChannel(context, sound = true, haptics = true) { "Rest" }
        assertNull("the pre-split channel is gone", manager.getNotificationChannel("training_rest"))
        assertTrue(manager.getNotificationChannel(on).shouldVibrate())
        val off = RestNotification.ensureChannel(context, sound = true, haptics = false) { "Rest" }
        assertNotEquals(on, off)
        assertFalse("vibration off in Settings reaches the notification", manager.getNotificationChannel(off).shouldVibrate())
        val silent = RestNotification.ensureChannel(context, sound = false, haptics = false) { "Rest" }
        assertNull(manager.getNotificationChannel(silent).sound)
    }

    @Test fun aRunningRestRoundTripsThroughTheSavedState() {
        val running = RunningRest("set-1", endsAtMs = 2_000_000L, startedAtMs = 1_900_000L)
        assertEquals(running, RunningRest.fromSaved(RunningRest.toSaved(running)))
        val paused = running.copy(pausedLeftMs = 42_000L)
        assertEquals(paused, RunningRest.fromSaved(RunningRest.toSaved(paused)))
        assertNull(RunningRest.fromSaved(null))
    }

    @Test fun aRecreationKeepsTheAlarmWhileSkippingWithdrawsIt() {
        assertFalse(restDisposeCancels(changingConfigurations = true, paused = false, nowMs = 0, endsAtMs = 60_000))
        assertTrue(restDisposeCancels(changingConfigurations = false, paused = false, nowMs = 0, endsAtMs = 60_000))
        assertFalse("a rest that ran out keeps its alarm, which fires now",
                    restDisposeCancels(changingConfigurations = false, paused = false, nowMs = 60_000, endsAtMs = 60_000))
    }
}
