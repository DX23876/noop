package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Settings › Strap Actions and Notifications (Android parity, package 3). The rules behind the heart-rate ceiling and
 * the Training Load alert are the shared core's and are tested there (`CoreAlertsTests`); here the pages are the Forge
 * pages, with the screens they open one level down,.
 */
class ForgeSettingsAlertsTest {

    @Test
    fun strapActionsAndNotificationsAreForgePagesNotHostedClassicScreens() {
        assertFalse(ForgeSettingsPage.StrapActions.hosted)
        assertFalse(ForgeSettingsPage.Notifications.hosted)
    }

    @Test
    fun theScreensBelowThePagesAreRegisteredSoTheyCanBeOpenedAndRestored() {
        val names = ForgeSettingsSub.entries.map { it.name }
        assertTrue(names.containsAll(listOf("WristAlerts", "NapDetection", "Rhythm")))
        // The classic hosts the nap detection and the per-app wrist alerts keep their own screens.
        assertEquals(null, ForgeSettingsSub.WristAlerts.cards)
        assertFalse(ForgeSettingsSub.WristAlerts.closes)
    }
}
