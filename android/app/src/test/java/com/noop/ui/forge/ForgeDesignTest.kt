package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Test

/** The two tab rosters: the shipped Forge set and the new design's, as iOS's `RootTabView` has them. */
class ForgeDesignTest {
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
