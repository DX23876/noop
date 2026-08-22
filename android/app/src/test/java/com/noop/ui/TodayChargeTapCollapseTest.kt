package com.noop.ui

import com.noop.R
import com.noop.analytics.ReadinessEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A1/S4/S5 parity twins of the iOS TodayChargeTapCollapseTests: the one-word readiness read kept on the
 * hero (#205), the collapsed "Synced from: ..." footer summary (S5), and the metrics-grid overflow cap
 * (S5). These mirror the Swift TodayView.readinessWord / syncedFromSummary / metricsCollapsedCap EXACTLY,
 * so a drift in either platform's labels/numbers fails here.
 */
class TodayChargeTapCollapseTest {

    @Test
    fun readinessWord_mapsEveryLevel() {
        assertEquals(R.string.today_readiness_push, readinessWord(ReadinessEngine.Level.PRIMED))
        assertEquals(R.string.today_readiness_maintain, readinessWord(ReadinessEngine.Level.BALANCED))
        assertEquals(R.string.today_readiness_rest, readinessWord(ReadinessEngine.Level.STRAINED))
        assertEquals(R.string.today_readiness_rest, readinessWord(ReadinessEngine.Level.RUNDOWN))
    }

    @Test
    fun readinessWord_insufficientHasNoWord() {
        assertNull(readinessWord(ReadinessEngine.Level.INSUFFICIENT))
    }

    @Test
    fun syncedFromSummary_listsOnlySourcesWithData() {
        assertEquals(
            listOf(DisplayText.Resource(R.string.today_source_whoop), DisplayText.Resource(R.string.today_source_apple_watch)),
            syncedFromSummary(hasWhoop = true, hasApple = true, hasXiaomi = false),
        )
        assertEquals(
            listOf(DisplayText.Resource(R.string.today_source_whoop)),
            syncedFromSummary(hasWhoop = true, hasApple = false, hasXiaomi = false),
        )
        assertEquals(
            listOf(DisplayText.Resource(R.string.today_source_whoop), DisplayText.Resource(R.string.today_source_apple_watch), DisplayText.Resource(R.string.today_source_mi_band)),
            syncedFromSummary(hasWhoop = true, hasApple = true, hasXiaomi = true),
        )
    }

    @Test
    fun syncedFromSummary_appleHealthReadsAsAppleWatch() {
        assertEquals(
            listOf(DisplayText.Resource(R.string.today_source_apple_watch)),
            syncedFromSummary(hasWhoop = false, hasApple = true, hasXiaomi = false),
        )
    }

    @Test
    fun syncedFromSummary_healthConnectReadsAsHealthConnect() {
        // #176: a Health-Connect-only user must NOT see "Synced from: Apple Watch".
        assertEquals(
            listOf(DisplayText.Resource(R.string.today_source_health_connect)),
            syncedFromSummary(hasWhoop = false, hasApple = false, hasHealthConnect = true, hasXiaomi = false),
        )
        assertEquals(
            listOf(DisplayText.Resource(R.string.today_source_whoop), DisplayText.Resource(R.string.today_source_health_connect)),
            syncedFromSummary(hasWhoop = true, hasApple = false, hasHealthConnect = true, hasXiaomi = false),
        )
        assertEquals(
            listOf(DisplayText.Resource(R.string.today_source_whoop), DisplayText.Resource(R.string.today_source_apple_watch), DisplayText.Resource(R.string.today_source_health_connect)),
            syncedFromSummary(hasWhoop = true, hasApple = true, hasHealthConnect = true, hasXiaomi = false),
        )
    }

    @Test
    fun syncedFromSummary_noSourcesIsHonest() {
        assertEquals(
            emptyList<DisplayText>(),
            syncedFromSummary(hasWhoop = false, hasApple = false, hasXiaomi = false),
        )
    }

    @Test
    fun metricsCollapsedCap_isSixTilesThreeRows() {
        assertEquals(6, METRICS_COLLAPSED_CAP)
    }

    @Test
    fun metricsCollapse_keepsLeadingTilesInOrder() {
        // The collapse slices from the FRONT of the saved order, so a pinned/selected tile is never
        // dropped or reordered (#251); only the tail folds. Mirrors MetricGrid's take(cap).
        val saved = (0 until 10).toList()
        val visible = if (saved.size <= METRICS_COLLAPSED_CAP) saved else saved.take(METRICS_COLLAPSED_CAP)
        assertEquals(listOf(0, 1, 2, 3, 4, 5), visible)
    }
}
