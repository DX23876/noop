package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Test

/** Today's widgets in the new design: sizes, moving, the rows they fill and the stored form (iOS `ForgeTodayWidgets`). */
class TodayWidgetsTest {
    private fun m(id: String, span: Int = 1) = TodayWidget(id, TodayWidget.Kind.Measure, "hrv", span)
    private fun card(id: String) = TodayWidget(id, TodayWidget.Kind.Goals)

    @Test fun sizesCycleSmallMediumSmallAndLiveHeartGoesWide() {
        val small = m("a")
        assertEquals(TodayWidget.Size.Medium, small.nextSize().size)
        assertEquals(TodayWidget.Size.Small, small.nextSize().nextSize().size)
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
}
