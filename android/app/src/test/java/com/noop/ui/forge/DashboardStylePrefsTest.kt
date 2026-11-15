package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
