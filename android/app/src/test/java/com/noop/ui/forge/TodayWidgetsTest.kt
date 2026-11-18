package com.noop.ui.forge

import com.noop.ui.KeyMetric
import org.junit.Assert.assertEquals
import org.junit.Test

/** Today's widgets in the new design: sizes, moving, the rows they fill and the stored form (iOS `ForgeTodayWidgets`). */
class TodayWidgetsTest {
    private fun m(id: String, span: Int = 1) = TodayWidget(id, TodayWidget.Kind.Measure, "hrv", span)
    private fun card(id: String) = TodayWidget(id, TodayWidget.Kind.Goals)

    /// A measure's own ladder moved to `aMeasureNowGrowsAcrossTheRowToo` when it gained the row-wide form.
    @Test fun sizesCycleAndLiveHeartGoesWide() {
        val water = TodayWidget("w", TodayWidget.Kind.Water)
        assertEquals(TodayWidget.Size.Medium, water.nextSize().size)
        assertEquals(TodayWidget.Size.Small, water.nextSize().nextSize().size)
        val heart = TodayWidget("h", TodayWidget.Kind.LiveHeart)
        assertEquals(TodayWidget.Size.Wide, heart.nextSize().nextSize().size)
        assertEquals(TodayWidget.Size.Small, heart.nextSize().nextSize().nextSize().size)
        assertEquals(TodayWidget.Size.Wide, card("g").size)
    }

    @Test fun rowsFillByWidth() {
        val rows = TodayWidgets.rows(listOf(m("a"), m("b"), m("c"), card("g"), m("d", span = 2), m("e")), columns = 2)
        assertEquals(listOf(listOf("a", "b"), listOf("c"), listOf("g"), listOf("d"), listOf("e")), rows.map { r -> r.map { it.id } })
        val three = TodayWidgets.rows(listOf(m("a"), m("b", span = 2), m("c")), columns = 3)
        assertEquals(listOf(listOf("a", "b"), listOf("c")), three.map { r -> r.map { it.id } })
    }

    @Test fun shiftMovesOnePlaceAndStopsAtTheEnds() {
        val list = listOf(m("a"), m("b"), m("c"))
        assertEquals(listOf("b", "a", "c"), TodayWidgets.shift(list, "a", 1).map { it.id })
        assertEquals(list, TodayWidgets.shift(list, "a", -1))
        assertEquals(list, TodayWidgets.shift(list, "c", 1))
    }

    @Test fun moveTakesTheTileOutAndPutsItWhereTheTargetStands() {
        val list = listOf(m("a"), m("b"), m("c"), m("d"))
        assertEquals(listOf("b", "c", "a", "d"), TodayWidgets.move(list, "a", "c").map { it.id })
        assertEquals(listOf("d", "a", "b", "c"), TodayWidgets.move(list, "d", "a").map { it.id })
        assertEquals(list, TodayWidgets.move(list, "a", "a"))
        assertEquals(list, TodayWidgets.move(list, "a", "x"))
    }

    @Test fun storedFormRoundTrips() {
        val list = listOf(m("a", span = 2), card("g"), TodayWidget("h", TodayWidget.Kind.LiveHeart, wide = true))
        assertEquals(list, TodayWidgets.decode(TodayWidgets.encode(list)))
        assertEquals(emptyList<TodayWidget>(), TodayWidgets.decode("not json"))
    }

    // Carrying an existing Today into the new design (owner, 2026-11-18), iOS's `ForgeTodayTileSeedTests`.
    // The promise is "nothing gets rearranged": an arranged Key-Metrics layout comes over as the same
    // metrics in the same order, an untouched one gets the set Today has always placed.

    private fun keys(selection: String?) = TodayWidgets.firstTiles(selection).map { it.key }

    @Test fun noSavedLayoutKeepsTheFixedFirstSet() {
        assertEquals(TodayWidgets.firstSet, TodayWidgets.firstTiles(null))
        assertEquals(TodayWidgets.firstSet, TodayWidgets.firstTiles("   "))
    }

    @Test fun aSavedLayoutIsCarriedInItsOwnOrder() {
        assertEquals(listOf("weight", "hrv", "steps"), keys("weight,hrv,steps"))
    }

    /** The rings directly above already say today's number, and these exist as tiles only across the row. */
    @Test fun chargeEffortAndRestAreNotCarried() {
        assertEquals(listOf("hrv"), keys("charge,effort,rest,hrv"))
    }

    /** A metric the gallery has no tile for is dropped, not placed empty. */
    @Test fun aMetricWithoutATileIsDropped() {
        assertEquals(listOf("hrv"), keys("hrv,somethingTheGalleryNeverHeardOf"))
    }

    /**
     * The gallery is iOS's list (2026-11-18). The three catalogue measures are the ones Android could
     * always have shown and did not, and Charge, Effort and Rest are out because they come back as
     * whole-row tiles. `calories_in` is the one entry iOS still has and Android does not.
     */
    @Test fun theGalleryOffersIosList() {
        assertEquals(listOf("hrv", "restingHr", "steps", "sleep_total_min", "vo2max_est", "stress",
                            "weight", "bloodOxygen", "respiratory", "skinTemp", "calories", "fitness_age",
                            "recovery", "strain", "sleep_performance"),
                     TodayWidgets.measures)
        assertEquals(TodayWidgets.catalogMeasures, TodayWidgets.measures.filter { it in TodayWidgets.catalogMeasures })
    }

    // The size ladder (owner, 2026-11-18): small, two columns, the whole row, and back.

    @Test fun aMeasureNowGrowsAcrossTheRowToo() {
        val small = m("a")
        assertEquals(TodayWidget.Size.Medium, small.nextSize().size)
        assertEquals(TodayWidget.Size.Wide, small.nextSize().nextSize().size)
        assertEquals(TodayWidget.Size.Small, small.nextSize().nextSize().nextSize().size)
    }

    /**
     * Charge, Effort and Rest have one size, so they carry no size control: a button that does nothing
     * says something untrue about the thing it sits on.
     */
    @Test fun theThreeTheRingsShowAreWholeRowAndCarryNoSizeControl() {
        for (key in TodayWidget.WHOLE_ROW_MEASURES) {
            val w = TodayWidget("x", TodayWidget.Kind.Measure, key)
            assertEquals(key, TodayWidget.Size.Wide, w.size)
            assertEquals(key, false, w.resizable)
            assertEquals(key, true, w.isWholeRowMeasure)
        }
    }

    @Test fun anOrdinaryMeasureIsNotAWholeRowOne() {
        assertEquals(false, m("a").isWholeRowMeasure)
        assertEquals(true, m("a").resizable)
    }

    @Test fun everyMetricEitherCarriesOrIsOneOfTheThree() {
        for (metric in KeyMetric.entries) {
            val carried = metric.measureKey
            if (metric == KeyMetric.CHARGE || metric == KeyMetric.EFFORT || metric == KeyMetric.REST) {
                assertEquals("${metric.raw} is a whole-row tile, not a carried one", null, carried)
            } else {
                assertEquals("${metric.raw} has nowhere to go", metric.raw, carried)
            }
        }
    }
}
