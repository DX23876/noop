package com.noop.ui.forge

import com.noop.ui.KeyMetric
import com.noop.ui.SleepSection
import com.noop.ui.TodayLayoutPrefs
import com.noop.ui.TodaySection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Forge layout editors after the Apple `LiquidTodayDefaults`, `EditableLayoutDraft` and the sheets' save. */
class ForgeTodayLayoutTest {
    @Test
    fun anUntouchedLayoutReadsTheLiquidFreshDefault() {
        assertFalse(TodayLayoutDefaults.isLayoutCustomised(null, null))
        // `LiquidTodayDefaults`: everything but the hidden Recovery Vitals and the excluded Data Sources.
        assertEquals(
            listOf(TodaySection.HERO, TodaySection.SYNTHESIS, TodaySection.GOALS, TodaySection.KEY_METRICS,
                   TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.WORKOUTS, TodaySection.HEART_RATE,
                   TodaySection.YOUR_CARDS, TodaySection.COACH, TodaySection.LIVE_SESSION, TodaySection.MENSTRUAL_CYCLE,
                   TodaySection.JOURNAL, TodaySection.ADDED_CARDS),
            TodayLayoutDefaults.visibleSections(null, null),
        )
    }

    /** Unhiding everything writes an explicit "", which must still count as the user's layout. */
    @Test
    fun anEmptyHiddenStringIsACustomisedLayout() {
        assertTrue(TodayLayoutDefaults.isLayoutCustomised(null, ""))
        assertTrue(TodayLayoutDefaults.isLayoutCustomised("hero", null))
        assertEquals(TodaySection.defaultOrder.filterNot { it in TodayLayoutDefaults.excludedSections },
                     TodayLayoutDefaults.visibleSections(null, ""))
    }

    @Test
    fun aSavedLayoutWinsAndHiddenSectionsStayOutOfTheScreen() {
        val order = "energy,heartRate,goals,hero,yourCards,coach,liveSession,synthesis,keyMetrics"
        // The stored sections keep their order; the ones the string leaves out return at their default places.
        assertEquals(
            listOf(TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.WORKOUTS, TodaySection.GOALS,
                   TodaySection.HERO, TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS, TodaySection.COACH,
                   TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
                   TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.ADDED_CARDS),
            TodayLayoutDefaults.visibleSections(order, "heartRate"),
        )
        val draft = TodayLayoutDefaults.sectionDraft(order, "heartRate")
        assertEquals(listOf(TodaySection.HEART_RATE), draft.hidden)
    }

    /**
     * Saving keeps every section Android leaves out: appended in default order, hidden only where it was, so the
     * iPhone (or a later Android with that card) finds them as they were.
     */
    @Test
    fun savingKeepsTheExcludedSectionsAndTheirVisibility() {
        val draft = EditableLayoutDraft(
            listOf(TodaySection.KEY_METRICS, TodaySection.HERO, TodaySection.ENERGY, TodaySection.SYNTHESIS,
                   TodaySection.GOALS, TodaySection.COACH),
            listOf(TodaySection.HEART_RATE),
        )
        val (order, hidden) = TodayLayoutDefaults.encodeSections(draft, setOf(TodaySection.RECOVERY_VITALS, TodaySection.HEART_RATE))
        assertEquals(
            // Only Data Sources is left out of Forge Today now, as `LiquidTodayDefaults.excludedSections`.
            "keyMetrics,hero,energy,synthesis,goals,coach,heartRate,dataSources",
            order,
        )
        // Recovery Vitals is drawn now, so it is the editor's to show or hide, not carried as an excluded section.
        assertEquals("heartRate", hidden)
        assertEquals(TodaySection.entries.size, TodayLayoutPrefs.decodeOrder(order).size)
    }

    @Test
    fun resetRestoresTheFreshLayout() {
        val reset = TodayLayoutDefaults.defaultSectionDraft()
        assertEquals(TodayLayoutDefaults.visibleSections(null, null), reset.visible)
        assertEquals(listOf(TodaySection.RECOVERY_VITALS), reset.hidden)
    }

    @Test
    fun theDraftHidesShowsAndMovesButKeepsOneItemShown() {
        var draft = EditableLayoutDraft.of(listOf(KeyMetric.HRV, KeyMetric.STEPS), KeyMetric.entries.toList())
        assertEquals(KeyMetric.entries.size - 2, draft.hidden.size)
        draft = draft.hide(KeyMetric.STEPS)
        assertEquals(listOf(KeyMetric.HRV), draft.visible)
        assertEquals(KeyMetric.STEPS, draft.hidden.last())
        assertEquals(draft, draft.hide(KeyMetric.HRV))
        assertEquals(emptyList<KeyMetric>(), draft.hide(KeyMetric.HRV, allowEmpty = true).visible)
        draft = draft.show(KeyMetric.STEPS).show(KeyMetric.CHARGE)
        assertEquals(listOf(KeyMetric.HRV, KeyMetric.STEPS, KeyMetric.CHARGE), draft.visible)
        assertEquals(listOf(KeyMetric.CHARGE, KeyMetric.HRV, KeyMetric.STEPS), draft.moveVisible(2, 0).visible)
        assertEquals(draft, draft.moveVisible(0, 5))
    }

    /** An automatic selection drops tiles without a value; a chosen one keeps them after the others. */
    @Test
    fun emptyTilesAreDroppedOnlyFromTheDefaultSelection() {
        val hasValue = { m: KeyMetric -> m != KeyMetric.HRV }
        val auto = TodayLayoutDefaults.keyMetricSelection(null)
        assertFalse(auto.isExplicit)
        assertEquals(listOf(KeyMetric.RESTING_HR, KeyMetric.BLOOD_OXYGEN, KeyMetric.RESPIRATORY, KeyMetric.STEPS,
                            KeyMetric.WEIGHT), TodayLayoutDefaults.arrangedKeyMetrics(auto, hasValue))
        val chosen = TodayLayoutDefaults.keyMetricSelection("hrv,charge,steps")
        assertTrue(chosen.isExplicit)
        assertEquals(listOf(KeyMetric.CHARGE, KeyMetric.STEPS, KeyMetric.HRV),
                     TodayLayoutDefaults.arrangedKeyMetrics(chosen, hasValue))
    }

    @Test
    fun columnsFollowTheStoredChoiceTwoByDefaultAndOneForLargeText() {
        assertEquals(2, TodayLayoutDefaults.keyMetricsColumns(null, largeText = false))
        assertEquals(3, TodayLayoutDefaults.keyMetricsColumns(3, largeText = false))
        assertEquals(3, TodayLayoutDefaults.keyMetricsColumns(7, largeText = false))
        assertEquals(1, TodayLayoutDefaults.keyMetricsColumns(3, largeText = true))
    }

    @Test
    fun sleepSavesItsDrawnCardsAndKeepsTheOthersWhereTheyWere() {
        val orderRaw = "sleepDebt,bodyClock,stages,nightDetail"
        val draft = SleepLayoutDefaults.draft(orderRaw, "bodyClock")
        // Cards missing from a stored order come after it, as `decodeOrder` appends them.
        assertEquals(listOf(SleepSection.SLEEP_MARKS, SleepSection.SLEEP_DEBT, SleepSection.STAGES,
                            SleepSection.NIGHT_DETAIL, SleepSection.STAGES_VS_TYPICAL, SleepSection.ASLEEP_DURATION),
                     draft.visible)
        val (order, hidden) = SleepLayoutDefaults.encode(draft.hide(SleepSection.SLEEP_DEBT), orderRaw, "bodyClock")
        assertTrue(order, order.startsWith("sleepMarks,stages,nightDetail,stagesVsTypical,asleepDuration,"))
        assertEquals(setOf("sleepDebt", "bodyClock"), hidden.split(",").toSet())
        assertEquals(listOf(SleepSection.SLEEP_MARKS, SleepSection.STAGES, SleepSection.NIGHT_DETAIL,
                            SleepSection.STAGES_VS_TYPICAL, SleepSection.ASLEEP_DURATION),
                     SleepLayoutDefaults.visible(order, hidden))
        // Every iOS Sleep card is drawn now (Tools/test_android_ios_parity.py keeps it so).
        assertEquals(SleepSection.defaultOrder.filter { it in SleepLayoutDefaults.drawn },
                     SleepLayoutDefaults.defaultDraft().visible)
    }
}
