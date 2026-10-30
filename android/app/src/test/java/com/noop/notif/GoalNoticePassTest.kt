package com.noop.notif

import android.content.Context
import com.noop.ui.NotifPrefs
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.Calendar
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Two goal passes started by back-to-back data updates must not both post the same notice, and a snoozed evening
 * reminder asks about the quiet hours at the time it would fire, as iOS (`GoalNotifier.isQuiet(fire)`).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE, application = android.app.Application::class)
class GoalNoticePassTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @After fun tearDown() {
        NotifPrefs.setBool(context, NotifPrefs.QUIET, false)
    }

    @Test fun overlappingPassesPostANoticeOnce() {
        var stored: String? = null
        val posted = AtomicInteger(0)
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(8)
        repeat(8) {
            pool.execute {
                start.await()
                GoalNoticeNotifier.serializedPass(
                    read = { stored },
                    // The core posts "reached" once and counts it in the state it hands back.
                    compute = { state ->
                        Thread.sleep(5)
                        if (state == "reached-posted") "reached-posted" to emptyList()
                        else "reached-posted" to listOf("Goal reached")
                    },
                    write = { stored = it },
                    deliver = { messages -> posted.addAndGet(messages.size) },
                )
            }
        }
        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(10, TimeUnit.SECONDS))
        assertEquals(1, posted.get())
    }

    @Test fun snoozeChecksTheQuietHoursAtItsFireTime() {
        NotifPrefs.setBool(context, NotifPrefs.QUIET, true)
        NotifPrefs.setInt(context, NotifPrefs.QUIET_START, 19 * 60)
        NotifPrefs.setInt(context, NotifPrefs.QUIET_END, 20 * 60)
        fun at(hour: Int, minute: Int) = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, minute)
        }
        // Snoozed at 18:30: not quiet now, quiet when it would fire at 19:30.
        assertFalse(NotifPrefs.inQuietHours(context, at(18, 30)))
        val fire = at(19, 30)
        assertTrue(NotifPrefs.inQuietHours(context, fire))
        assertFalse(GoalNoticeNotifier.snoozeMayFire(19 * 60 + 30, NotifPrefs.inQuietHours(context, fire)))
        assertTrue(GoalNoticeNotifier.snoozeMayFire(20 * 60 + 30, NotifPrefs.inQuietHours(context, at(20, 30))))
        assertFalse("never past 21:00", GoalNoticeNotifier.snoozeMayFire(21 * 60, false))
    }

    @Test fun aQuietWindowAcrossMidnightWraps() {
        assertTrue(NotifPrefs.quietAt(23 * 60, 22 * 60, 7 * 60))
        assertTrue(NotifPrefs.quietAt(6 * 60, 22 * 60, 7 * 60))
        assertFalse(NotifPrefs.quietAt(12 * 60, 22 * 60, 7 * 60))
    }
}
