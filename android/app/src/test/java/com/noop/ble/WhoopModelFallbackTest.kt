package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the BLE scan-family fallback rotation (PR#195): a service-filtered scan that finds nothing rotates
 * to the OTHER WHOOP family in case the persisted preference went stale after an update/restore. Kotlin
 * twin of macOS WhoopModelFallbackTests.
 */
class WhoopModelFallbackTest {

    @Test
    fun fallbackRotatesBetweenFamilies() {
        assertEquals(WhoopModel.WHOOP5_MG, WhoopModel.WHOOP4.fallbackScanModel)
        assertEquals(WhoopModel.WHOOP4, WhoopModel.WHOOP5_MG.fallbackScanModel)
    }

    @Test
    fun fallbackIsInvolution() {
        assertEquals(WhoopModel.WHOOP4, WhoopModel.WHOOP4.fallbackScanModel.fallbackScanModel)
        assertEquals(WhoopModel.WHOOP5_MG, WhoopModel.WHOOP5_MG.fallbackScanModel.fallbackScanModel)
    }
}
