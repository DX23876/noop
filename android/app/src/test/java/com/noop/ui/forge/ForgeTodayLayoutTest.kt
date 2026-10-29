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
    fun anUntouchedLayoutReadsTheFreshDefaultWithoutTheSectionsAndroidDoesNotDraw() {
        assertFalse(TodayLayoutDefaults.isLayoutCustomised(null, null))
        assertEquals(
            listOf(TodaySection.HERO, TodaySection.SYNTHESIS, TodaySection.GOALS, TodaySection.KEY_METRICS,
                   TodaySection.ENERGY, TodaySection.HEART_RATE, TodaySection.COACH),
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
        assertEquals(
            listOf(TodaySection.ENERGY, TodaySection.GOALS, TodaySection.HERO, TodaySection.COACH,
                   TodaySection.SYNTHESIS, TodaySection.KEY_METRICS),
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
            "keyMetrics,hero,energy,synthesis,goals,coach,heartRate," +
                "liveSession,trainingLoad,workouts,recoveryVitals,yourCards,menstrualCycle,journal,dataSources,addedCards",
            order,
        )
        assertEquals("heartRate,recoveryVitals", hidden)
        assertEquals(TodaySection.entries.size, TodayLayoutPrefs.decodeOrder(order).size)
        assertEquals(draft.visible, TodayLayoutDefaults.visibleSections(order, hidden))
    }

    @Test
    fun resetRestoresTheFreshLayout() {
        val reset = TodayLayoutDefaults.defaultSectionDraft()
        assertEquals(TodayLayoutDefaults.visibleSections(null, null), reset.visible)
        assertTrue(reset.hidden.isEmpty())
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
        assertEquals(listOf(SleepSection.SLEEP_DEBT, SleepSection.STAGES, SleepSection.STAGES_VS_TYPICAL,
                            SleepSection.ASLEEP_DURATION), draft.visible)
        val (order, hidden) = SleepLayoutDefaults.encode(draft.hide(SleepSection.SLEEP_DEBT), orderRaw, "bodyClock")
        assertTrue(order, order.startsWith("stages,stagesVsTypical,asleepDuration,sleepDebt,sleepMarks,bodyClock,nightDetail,"))
        assertEquals("sleepDebt,bodyClock", hidden)
        assertEquals(listOf(SleepSection.STAGES, SleepSection.STAGES_VS_TYPICAL, SleepSection.ASLEEP_DURATION),
                     SleepLayoutDefaults.visible(order, hidden))
        assertEquals(listOf(SleepSection.STAGES, SleepSection.SLEEP_DEBT, SleepSection.STAGES_VS_TYPICAL,
                            SleepSection.ASLEEP_DURATION), SleepLayoutDefaults.defaultDraft().visible)
    }
}
