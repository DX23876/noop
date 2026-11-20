package com.noop.ui.forge

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The two tab rosters: the shipped Forge set and the new design's, as iOS's `RootTabView` has them. */
class ForgeDesignTest {

    private fun on(p: SharedPreferences) = p.getBoolean(ForgeDesign.KEY, ForgeDesign.DEFAULT)

    /** The case the plain default flip would miss: someone who had deliberately turned the preview off. */
    @Test fun theOneTimeFlipReachesAnInstallThatHadItOff() {
        val p = FakePrefs()
        p.edit().putBoolean(ForgeDesign.KEY, false).apply()
        ForgeDesign.flipOnce(p)
        assertTrue(on(p))
    }

    /** Without this the clear would run at every launch and nobody could ever leave the new design. */
    @Test fun anOffChosenAfterTheFlipSurvives() {
        val p = FakePrefs()
        ForgeDesign.flipOnce(p)
        p.edit().putBoolean(ForgeDesign.KEY, false).apply()
        ForgeDesign.flipOnce(p)
        assertFalse(on(p))
    }

    @Test fun theFlipIsMarkedAndTheDefaultIsNowOn() {
        val p = FakePrefs()
        assertTrue(ForgeDesign.DEFAULT)
        assertFalse(p.getBoolean(ForgeDesign.FLIPPED_KEY, false))
        ForgeDesign.flipOnce(p)
        assertTrue(p.getBoolean(ForgeDesign.FLIPPED_KEY, false))
    }

    /** The case [flipOnce] deliberately left alone: an "off" set after 18 November was a decision, and it
     *  survived. There is nothing to decide any more, so this one clears it too. */
    @Test fun retiringReachesAnOffChosenAfterTheFlip() {
        val p = FakePrefs()
        ForgeDesign.flipOnce(p)
        p.edit().putBoolean(ForgeDesign.KEY, false).apply()
        assertFalse(on(p))
        ForgeDesign.retireTheOldDesign(p)
        assertTrue(on(p))
    }

    /** Its own marker, or the clear would run at every launch and nothing could ever be stored again. */
    @Test fun retiringRunsOnce() {
        val p = FakePrefs()
        assertFalse(p.getBoolean(ForgeDesign.RETIRED_KEY, false))
        ForgeDesign.retireTheOldDesign(p)
        assertTrue(p.getBoolean(ForgeDesign.RETIRED_KEY, false))
        p.edit().putBoolean(ForgeDesign.KEY, false).apply()
        ForgeDesign.retireTheOldDesign(p)
        assertFalse(on(p))
    }

    // In-memory SharedPreferences: remove() must really remove, which is the whole mechanism here.
    private class FakePrefs : SharedPreferences {
        private val map = HashMap<String, Any?>()
        override fun getInt(key: String, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = map[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = map[key] as? Boolean ?: defValue
        override fun getString(key: String, defValue: String?): String? = map[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            map[key] as? MutableSet<String> ?: defValues
        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun contains(key: String): Boolean = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun edit(): SharedPreferences.Editor = FakeEditor()

        private inner class FakeEditor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removed = HashSet<String>()
            override fun putString(key: String, value: String?): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor { pending[key] = values; return this }
            override fun putInt(key: String, value: Int): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putLong(key: String, value: Long): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor { pending[key] = value; return this }
            override fun remove(key: String): SharedPreferences.Editor { removed.add(key); return this }
            override fun clear(): SharedPreferences.Editor { map.clear(); return this }
            override fun commit(): Boolean { flush(); return true }
            override fun apply() { flush() }
            private fun flush() {
                for (k in removed) map.remove(k)
                map.putAll(pending)
                pending.clear(); removed.clear()
            }
        }
    }
    @Test fun shippedTabsKeepTrendsAndMore() {
        assertEquals(listOf(ForgeTab.Today, ForgeTab.Trends, ForgeTab.Training, ForgeTab.Sleep, ForgeTab.More),
                     ForgeDesign.tabs(newDesign = false, coachEnabled = true))
    }

    @Test fun newDesignHasHealthAndTheCoachOnlyWhileOn() {
        assertEquals(listOf(ForgeTab.Today, ForgeTab.Training, ForgeTab.Sleep, ForgeTab.Health, ForgeTab.Coach),
                     ForgeDesign.tabs(newDesign = true, coachEnabled = true))
        assertEquals(listOf(ForgeTab.Today, ForgeTab.Training, ForgeTab.Sleep, ForgeTab.Health),
                     ForgeDesign.tabs(newDesign = true, coachEnabled = false))
    }
}
