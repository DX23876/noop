package com.noop.ui.forge

import android.content.SharedPreferences
import com.noop.core.CoreProfile
import com.noop.ui.ProfileStore
import com.noop.ui.UnitSystem
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/**
 * Settings › Profile and Training (Android parity, package 1): the stored half of what the pages draw. The rules that
 * decide a legal set of zones live in the shared core and are tested there (`CoreProfileTests`); here the profile keeps
 * what the page gave it, reads the old one-key zones, and rescales the percent mode with the maximum.
 *
 * No Robolectric: the real [ProfileStore] runs over an in-memory preferences object.
 */
class ForgeSettingsHrZonesTest {

    @Test
    fun zonesStartStandardAndAnOldBpmSetCountsAsTheBeatsMode() {
        val prefs = FakePrefs()
        val profile = ProfileStore(prefs)
        assertEquals("auto", profile.hrZoneMode)
        assertNull(profile.hrZoneLowerBounds)
        assertFalse(profile.hasCustomHrZones)

        // A set saved before the modes existed (one key, five beats) still reads, as the Apple store adopts it.
        prefs.edit().putString("hr_zone_thresholds", "110,125,140,155,170").apply()
        assertEquals("bpm", profile.hrZoneMode)
        assertEquals(listOf(110, 125, 140, 155, 170), profile.hrZoneThresholds)
        assertTrue(profile.hasCustomHrZones)
    }

    @Test
    fun theModeNotInUseKeepsItsNumbersWhenTheOtherIsSaved() {
        val profile = ProfileStore(FakePrefs())
        profile.setHrZoneConfig("percent", listOf(55.0, 65.0, 75.0, 85.0, 92.0), listOf(1.0, 2.0, 3.0, 4.0, 5.0))
        profile.setHrZoneConfig("bpm", listOf(1.0, 1.0, 1.0, 1.0, 1.0), listOf(110.0, 125.0, 140.0, 155.0, 170.0))
        profile.hrZoneMode = "percent"
        // The percent set typed first is still there, and only the chosen mode's own bounds were written each time.
        assertEquals(listOf(55.0, 65.0, 75.0, 85.0, 92.0), profile.hrZonePercents)
        assertEquals(listOf(110.0, 125.0, 140.0, 155.0, 170.0), profile.hrZoneBpms)
    }

    @Test
    fun percentBoundsFollowTheMaximumAndBeatsStayPut() {
        val prefs = FakePrefs()
        val profile = ProfileStore(prefs)
        profile.hrMaxOverride = 200
        profile.setHrZoneConfig("percent", listOf(55.0, 65.0, 75.0, 85.0, 92.0), emptyList())
        assertEquals(listOf(110.0, 130.0, 150.0, 170.0, 184.0), profile.hrZoneLowerBounds?.map { Math.round(it * 10) / 10.0 })
        profile.hrMaxOverride = 190
        assertEquals(listOf(104.5, 123.5, 142.5, 161.5, 174.8), profile.hrZoneLowerBounds?.map { Math.round(it * 10) / 10.0 })

        profile.setHrZoneConfig("bpm", emptyList(), listOf(110.0, 125.0, 140.0, 155.0, 170.0))
        profile.hrMaxOverride = 200
        assertEquals(listOf(110.0, 125.0, 140.0, 155.0, 170.0), profile.hrZoneLowerBounds)
        // The zone set the readers bucket by is cut at those bounds.
        assertEquals(3, profile.hrZoneSet.zoneNumber(141.0))
    }

    @Test
    fun aSetThatIsNotAPartitionCountsAsAbsent() {
        val profile = ProfileStore(FakePrefs())
        profile.setHrZoneConfig("bpm", emptyList(), listOf(110.0, 125.0, 120.0, 155.0, 170.0))
        assertNull(profile.hrZoneLowerBounds)
        assertFalse(profile.hasCustomHrZones)
    }

    @Test
    fun theClassicSwitchStillTurnsCustomZonesOnAndOff() {
        val profile = ProfileStore(FakePrefs())
        profile.hrMaxOverride = 190
        profile.setCustomHrZonesEnabled(true)
        assertEquals("bpm", profile.hrZoneMode)
        assertEquals(5, profile.hrZoneThresholds?.size)
        assertEquals(95, profile.hrZoneThresholds?.first())   // half of 190, the conventional first start
        profile.stepHrZoneThreshold(0, up = true)
        assertEquals(96, profile.hrZoneThresholds?.first())
        profile.setCustomHrZonesEnabled(false)
        assertEquals("auto", profile.hrZoneMode)
    }

    @Test
    fun theBackupCarriesTheZonesAndTheAerobicCeilingAndRestoresThem() {
        val prefs = FakePrefs()
        val profile = ProfileStore(prefs)
        profile.setHrZoneConfig("percent", listOf(55.0, 65.0, 75.0, 85.0, 92.0), emptyList())
        profile.weightKg = 80.0
        profile.setManualVO2max(48.5)
        profile.activityLevelOverride = 4
        val snapshot = profile.backupSnapshot()
        assertEquals("percent", snapshot["profile.zoneMode"])
        assertEquals("55,65,75,85,92", snapshot["profile.zonePercentEdges"])
        assertEquals(48.5, snapshot["profile.vo2maxManual"] as Double, 1e-4)
        assertEquals(80.0, snapshot["profile.vo2maxManualWeightKg"] as Double, 1e-4)
        assertEquals(4, snapshot["profile.activityLevelOverride"])

        val other = ProfileStore(FakePrefs())
        other.applyBackup(snapshot)
        assertEquals("percent", other.hrZoneMode)
        assertEquals(listOf(55.0, 65.0, 75.0, 85.0, 92.0), other.hrZonePercents)
        assertEquals(48.5, other.vo2maxManual, 1e-4)
        assertEquals(snapshot["profile.vo2maxManualDay"], other.vo2maxManualDay)
        assertEquals(4, other.activityLevelOverride)
    }

    @Test
    fun anEnteredVo2maxRecordsTodayAndTheWeightAndClearsBackToAuto() {
        val profile = ProfileStore(FakePrefs())
        profile.weightKg = 92.0
        assertEquals(0.0, profile.vo2maxManual, 0.0)
        profile.setManualVO2max(41.0)
        assertEquals(41.0, profile.vo2maxManual, 1e-4)
        assertEquals(java.time.LocalDate.now().toString(), profile.vo2maxManualDay)
        assertEquals(92.0, profile.vo2maxManualWeightKg, 1e-4)
        profile.setManualVO2max(null)
        assertEquals(0.0, profile.vo2maxManual, 0.0)
        assertEquals("", profile.vo2maxManualDay)
    }

    @Test
    fun theActivityLevelStaysBetweenAutoAndFive() {
        val profile = ProfileStore(FakePrefs())
        profile.activityLevelOverride = 9
        assertEquals(5, profile.activityLevelOverride)
        profile.activityLevelOverride = -2
        assertEquals(0, profile.activityLevelOverride)
    }

    @Test
    fun aNonBinaryProfileCarriesItsOwnBodyEquation() {
        val profile = ProfileStore(FakePrefs())
        profile.sex = "male"; assertEquals("male", profile.bodyEquation)
        profile.sex = "female"; assertEquals("female", profile.bodyEquation)
        profile.sex = "nonbinary"
        assertEquals("", profile.bodyEquation)
        profile.bodyFormulaSex = "female"
        assertEquals("female", profile.bodyEquation)
        profile.bodyFormulaSex = "other"
        assertEquals("", profile.bodyFormulaSex)
    }

    @Test
    fun theAutomaticMaximumIsTheCoresForTheAgeItAnsweredFor() {
        val profile = ProfileStore(FakePrefs())
        profile.setAge(40)
        assertEquals(com.noop.analytics.Zones.hrMaxTanaka(40), profile.hrMaxAuto)   // before the core has answered: the age estimate
        profile.cacheCoreMaxHeartRate(40, 197, "measured", "2026-11-02")
        assertEquals(197, profile.hrMaxAuto)
        assertEquals("measured", profile.hrMaxAutoSource)
        assertEquals("2026-11-02", profile.hrMaxMeasuredOn)
        assertEquals(197, profile.hrMax)
        profile.hrMaxOverride = 185
        assertEquals(185, profile.hrMax)
        // A birthday later the answer is for another age, so it is not used until the core answers again.
        profile.setAge(41)
        assertEquals("", profile.hrMaxAutoSource)
        assertEquals(com.noop.analytics.Zones.hrMaxTanaka(41), profile.hrMaxAuto)
    }

    @Test
    fun theCoresZoneDraftIsReadAsTheScreenNeedsIt() {
        val draft = CoreProfile.parseZones(JSONObject("""
            {"mode":"bpm","percents":[50,60,70,80,90],"bpms":[100,120,140,160,180],"legal":true,"custom":true,
             "bounds":"100/120/140/160/180 bpm","lowerBpm":[100,120,140,160,180],
             "zones":[{"number":1,"lowerBpm":100,"upperBpm":119,"lowerPercentText":"50","upperPercentText":"60"},
                      {"number":5,"lowerBpm":180,"upperBpm":200,"lowerPercentText":"90","upperPercentText":"100"}]}"""))!!
        assertEquals("bpm", draft.mode)
        assertTrue(draft.legal && draft.custom)
        assertEquals(listOf(100.0, 120.0, 140.0, 160.0, 180.0), draft.bpms)
        assertEquals(119, draft.bands[0].upperBpm)
        assertEquals("90", draft.bands[1].lowerPercentText)
        assertEquals("100/120/140/160/180 bpm", draft.bounds)
    }

    @Test
    fun theWeightStepsAreLabelledInTheUnitTheWearerPicked() {
        val saved = Locale.getDefault()
        Locale.setDefault(Locale.US)
        try {
            assertEquals("2.5 kg", TrainingStepPrefs.label(2.5, UnitSystem.METRIC))
            assertEquals("1.25 kg", TrainingStepPrefs.label(1.25, UnitSystem.METRIC))
            assertEquals(listOf("1 lb", "2.5 lb", "5 lb", "10 lb"),
                         TrainingStepPrefs.poundChoicesKg.map { TrainingStepPrefs.label(it, UnitSystem.IMPERIAL) })
        } finally { Locale.setDefault(saved) }
    }

    /** In-memory preferences with the read and write contract [ProfileStore] relies on. */
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
}
