package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SuccessfulOffloadHookTest {
    @Test fun completeOrProductiveTimeoutNotifiesDownstream() {
        assertTrue(WhoopBleClient.shouldNotifySuccessfulOffload("HISTORY_COMPLETE", bankedRows = true))
        assertTrue(WhoopBleClient.shouldNotifySuccessfulOffload("timeout", bankedRows = true))
        assertFalse(WhoopBleClient.shouldNotifySuccessfulOffload("timeout", bankedRows = false))
        assertFalse(WhoopBleClient.shouldNotifySuccessfulOffload("aborted by user", bankedRows = true))
        assertFalse(WhoopBleClient.shouldNotifySuccessfulOffload("disconnect", bankedRows = true))
    }
}
