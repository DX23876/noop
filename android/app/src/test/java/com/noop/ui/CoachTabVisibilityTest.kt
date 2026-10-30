package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import android.content.Context
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The Coach master switch decides which trailing tabs the bar draws.
 *
 * Why this is a test rather than a filter trusted in place: #2218's note at the More slot records that
 * spelling the tab set out twice is what once lit Coach and More together, because the second copy had
 * never heard of the new tab. A CONDITIONAL tab makes that failure available again to anyone who filters
 * in one of the two places and not the other, so the shared helper is pinned here and both call sites are
 * required to come through it.
 */
class CoachTabVisibilityTest {

    @Test
    fun `coach enabled keeps the shipped trailing tabs`() {
        assertEquals(barTrailingTabs, barTrailingTabsFor(coachEnabled = true))
    }

    @Test
    fun `coach disabled drops the coach tab and nothing else`() {
        val visible = barTrailingTabsFor(coachEnabled = false)
        assertFalse("coach tab must not be drawn", visible.any { it.dest == Destination.Coach })
        assertEquals(
            "only Coach may be removed",
            barTrailingTabs.filterNot { it.dest == Destination.Coach },
            visible,
        )
    }

    @Test
    fun `coach on keeps the coach tab`() {
        // Since Android plan E-3f Coach is the classic bar's only tab, so the filter is pinned from the other
        // side: switched on, the tab is drawn.
        assertTrue(barTrailingTabsFor(coachEnabled = true).any { it.dest == Destination.Coach })
    }

}

/**
 * The stored default, which is the invariant that actually matters on upgrade: a fresh install starts with the
 * Coach off, as the fork's iOS does, and an install that already used the app keeps it on, so an update never
 * removes the Coach tab. Decided once at launch (`migrateCoachEnabledDefault`), never at read time.
 */
@RunWith(RobolectricTestRunner::class)
class CoachEnabledPrefDefaultTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun reset() {
        NoopPrefs.of(context).edit().remove(NoopPrefs.KEY_COACH_ENABLED).remove(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION).commit()
    }

    @Test
    fun `a fresh install starts with the coach off`() {
        reset()
        NoopPrefs.migrateCoachEnabledDefault(context)
        assertFalse(NoopPrefs.coachEnabled(context))
    }

    @Test
    fun `an install that already used the app keeps the coach on`() {
        reset()
        NoopPrefs.of(context).edit().putString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, "1").commit()
        NoopPrefs.migrateCoachEnabledDefault(context)
        assertTrue("an update must not take the Coach away", NoopPrefs.coachEnabled(context))
    }

    @Test
    fun `the decision is taken once and a choice is never overwritten`() {
        reset()
        NoopPrefs.migrateCoachEnabledDefault(context)
        // Accepting the terms later must not flip a fresh install's recorded value.
        NoopPrefs.of(context).edit().putString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, "1").commit()
        NoopPrefs.migrateCoachEnabledDefault(context)
        assertFalse(NoopPrefs.coachEnabled(context))
        NoopPrefs.setCoachEnabled(context, true)
        NoopPrefs.migrateCoachEnabledDefault(context)
        assertTrue(NoopPrefs.coachEnabled(context))
    }

    @Test
    fun `the stored value round-trips in both directions`() {
        NoopPrefs.setCoachEnabled(context, false)
        assertFalse(NoopPrefs.coachEnabled(context))
        NoopPrefs.setCoachEnabled(context, true)
        assertTrue(NoopPrefs.coachEnabled(context))
    }
}
