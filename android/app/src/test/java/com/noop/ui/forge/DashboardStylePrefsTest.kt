package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Overview left the Android style list (decided 2026-11-15, `docs/fork/decisions.md`): it drew the same
 * Forge Today as Liquid, with Liquid's own default order. Someone who had chosen it must land on Liquid,
 * not on a Today the shell cannot draw, and the styles that remain must not shift under them.
 */
class DashboardStylePrefsTest {

    @Test
    fun aStoredOverviewReadsAsLiquid() {
        assertEquals("liquid", DashboardStylePrefs.resolve("overview"))
    }

    @Test
    fun overviewIsNoLongerOffered() {
        assertFalse("overview" in DashboardStylePrefs.STYLES)
    }

    @Test
    fun everyStyleThisBuildDrawsResolvesToItself() {
        for (style in DashboardStylePrefs.STYLES) {
            assertEquals(style, DashboardStylePrefs.resolve(style))
        }
    }

    @Test
    fun nothingStoredAndNothingKnownBothReadAsTheDefault() {
        assertEquals("liquid", DashboardStylePrefs.DEFAULT)
        assertEquals("liquid", DashboardStylePrefs.resolve(null))
        assertEquals("liquid", DashboardStylePrefs.resolve(""))
        assertEquals("liquid", DashboardStylePrefs.resolve("forge"))
    }

    @Test
    fun anOverviewArrangementIsCarriedOverToLiquid() {
        // What the wearer arranged lives under "overview.dashboard.*"; resolving to Liquid alone would
        // read "liquid.dashboard.*" and leave their screen behind.
        val move = DashboardStylePrefs.carryOver("overview", null, null)
        assertEquals("overview", move?.from)
        assertEquals("liquid", move?.to)
        assertEquals(true, move?.order)
        assertEquals(true, move?.hidden)
    }

    @Test
    fun anArrangementTheTargetStyleAlreadyHasIsNeverOverwritten() {
        val move = DashboardStylePrefs.carryOver("overview", "coach,health,momentum", "momentum")
        assertEquals("liquid", move?.to)
        assertEquals(false, move?.order)
        assertEquals(false, move?.hidden)
    }

    @Test
    fun aStyleThisBuildOffersCarriesNothing() {
        for (style in DashboardStylePrefs.STYLES) {
            assertNull(DashboardStylePrefs.carryOver(style, null, null))
        }
        assertNull(DashboardStylePrefs.carryOver(null, null, null))
    }

    @Test
    fun everyOfferedStyleHasItsOwnLabel() {
        val labels = DashboardStylePrefs.STYLES.map { DashboardStylePrefs.labelRes(it) }
        assertEquals(DashboardStylePrefs.STYLES.size, labels.distinct().size)
    }
}
