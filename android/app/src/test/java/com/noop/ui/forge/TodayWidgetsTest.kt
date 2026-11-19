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
     * The gallery is iOS's list, grouped as the catalogue groups it (owner, 2026-11-18). The sections and
     * their order are part of it: a measure under another heading is a different gallery.
     * `Tools/test_today_tile_gallery.py` holds this against the Swift list on every push, since pinning it
     * here alone said nothing about the side it drifted from.
     */
    @Test fun theGalleryOffersIosListInIosSections() {
        assertEquals(listOf("recovery",
                            "sleep_performance", "sleep_total_min", "sleep_debt_min",
                            "strain", "steps", "calories", "hr_zones13_min", "hr_zones45_min",
                            "hrv", "restingHr", "bloodOxygen", "respiratory", "vo2max_est", "stress",
                            "weight", "body_fat", "lean_mass", "skinTemp", "fitness_age", "vitality", "body_age",
                            "calories_in", "protein_g",
                            "mood"),
                     TodayWidgets.measures)
        assertEquals(listOf(TodayWidgets.Section.Charge, TodayWidgets.Section.Rest, TodayWidgets.Section.Effort,
                            TodayWidgets.Section.Heart, TodayWidgets.Section.Body, TodayWidgets.Section.Food,
                            TodayWidgets.Section.Mind),
                     TodayWidgets.sections.map { it.first })
        // Every measure the Key Metrics reading does not carry has to be in the catalogue list, or its tile
        // is drawn by a path that has no number for it.
        val carried = KeyMetric.entries.map { it.raw } + TodayWidget.SLEEP_KEY
        assertEquals(emptyList<String>(),
                     TodayWidgets.measures.filter { it !in carried && it !in TodayWidgets.catalogMeasures })
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

    /**
     * The four cards whose two-column form says the two facts the owner's table gives it (2026-11-19).
     * They offer TWO sizes, never a small one: a card has no change chip and no sparkline, so it cannot
     * meet the floor a small tile has to meet, and one figure on a square is what the owner rejected.
     */
    @Test fun aCardOffersTwoColumnsButNeverOne() {
        assertEquals(setOf(TodayWidget.Kind.LastNight, TodayWidget.Kind.Tonight,
                           TodayWidget.Kind.LastWorkout, TodayWidget.Kind.Energy,
                           TodayWidget.Kind.Nutrition),
                     TodayWidget.SHRINKABLE_CARDS)
        for (kind in TodayWidget.SHRINKABLE_CARDS) {
            val placed = TodayWidget("x", kind)
            assertEquals(kind.name, TodayWidget.Size.Wide, placed.size)
            assertEquals(kind.name, true, placed.resizable)
            // Wide, two columns, wide: the control never offers the size there is no form for.
            assertEquals(kind.name, TodayWidget.Size.Medium, placed.nextSize().size)
            assertEquals(kind.name, TodayWidget.Size.Wide, placed.nextSize().nextSize().size)
            // Even a stored span of one reads as two columns, so an old entry cannot draw a form that
            // does not exist.
            assertEquals(kind.name, TodayWidget.Size.Medium, placed.copy(span = 1, wide = false).size)
        }
    }

    /** A card that was never resized starts wide: null must not read as small, or every Today placed
     * before the ladder existed would have been rearranged overnight. */
    @Test fun aCardThatCanShrinkStartsWide() {
        val card = TodayWidget("x", TodayWidget.Kind.LastNight)
        assertEquals(TodayWidget.Size.Wide, card.size)
        assertEquals(TodayWidget.Size.Wide, card.copy(wide = null).size)
    }

    /** A card that carries a sentence keeps its one size and shows no size control. */
    @Test fun aCardThatIsASentenceDoesNotShrink() {
        for (kind in listOf(TodayWidget.Kind.Momentum, TodayWidget.Kind.WeekPlan, TodayWidget.Kind.CoachNote,
                            TodayWidget.Kind.NextSession, TodayWidget.Kind.Changes, TodayWidget.Kind.WhatWorks)) {
            val w = TodayWidget("x", kind)
            assertEquals(kind.name, TodayWidget.Size.Wide, w.size)
            assertEquals(kind.name, false, w.resizable)
        }
    }

    /**
     * "wide" has to be stored as written, false included, not left out: a tile shrunk by the wearer must
     * not come back wide after a restart, and a tile never touched must keep its null.
     */
    @Test fun theStoredFormKeepsWhatTheWearerChose() {
        val shrunk = TodayWidget("a", TodayWidget.Kind.LiveHeart, wide = false)
        assertEquals(listOf(shrunk), TodayWidgets.decode(TodayWidgets.encode(listOf(shrunk))))
        val untouched = TodayWidget("b", TodayWidget.Kind.LastNight)
        assertEquals(null, TodayWidgets.decode(TodayWidgets.encode(listOf(untouched))).first().wide)
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
