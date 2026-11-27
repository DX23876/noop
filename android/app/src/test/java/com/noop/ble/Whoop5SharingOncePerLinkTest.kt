package com.noop.ble

import android.app.Application
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * A 5/MG gets the wearer's heart-rate sharing re-applied once per connection, as on Apple
 * (`whoop5SessionStarted`). Until 2026-11-26 it rode every offload kick, so the auto-continuing re-kicks of
 * one sync sent the same three writes again every few seconds.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE, application = Application::class)
class Whoop5SharingOncePerLinkTest {
    @Test
    fun onlyTheFirstClaimOfALinkAnswersTrue() {
        val once = LinkOnce()
        assertTrue(once.claim())
        assertFalse("a second offload kick on the same link sends nothing", once.claim())
        assertFalse(once.claim())
        once.reset()
        assertTrue("a new link applies it again", once.claim())
    }

    @Test
    fun theClientsDisconnectResetRearmsIt() {
        val client = WhoopBleClient(RuntimeEnvironment.getApplication())
        assertTrue(client.whoop5SharingOnce.claim())
        assertFalse(client.whoop5SharingOnce.claim())
        WhoopBleClient::class.java.getDeclaredMethod("reset").apply { isAccessible = true }.invoke(client)
        assertTrue("the per-connection reset re-arms the re-apply", client.whoop5SharingOnce.claim())
    }
}
