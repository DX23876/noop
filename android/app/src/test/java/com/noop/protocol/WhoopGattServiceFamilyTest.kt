package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WhoopGattServiceFamilyTest {
    @Test
    fun diagnosticFamiliesAreMetadataOnly() {
        assertEquals(
            listOf(
                "11500001-6215-11ee-8c99-0242ac120002",
                "8a580001-2fe8-4796-9267-b87a2b0c8234",
                "59830001-5955-419b-bb8d-c8262926af23",
            ),
            WhoopGattServiceFamily.unsupportedServiceUuidStrings,
        )

        for (family in WhoopGattServiceFamily.unsupportedFamilies) {
            assertFalse(family.isConnectable)
            assertNull(family.connectableDeviceFamily)
            assertTrue(family.diagnosticUnsupportedMessage.contains("will not connect or send commands"))
            assertEquals(5, family.characteristicUuidStrings.size)
        }
    }

    @Test
    fun supportedFamiliesRemainTheOnlyConnectableFamilies() {
        assertEquals(DeviceFamily.WHOOP4, WhoopGattServiceFamily.WHOOP4.connectableDeviceFamily)
        assertEquals(DeviceFamily.WHOOP5, WhoopGattServiceFamily.MAVERICK_GOOSE_FD4B.connectableDeviceFamily)
        assertEquals(
            "fd4b0001-cce1-4033-93ce-002d5875f58a",
            WhoopGattServiceFamily.MAVERICK_GOOSE_FD4B.serviceUuidString,
        )
    }

    @Test
    fun unsupportedAdvertisementsDoNotConnect() {
        val decision = whoopGattScanDecision(
            selectedServiceUuidString = DeviceFamily.WHOOP5.serviceUuidString,
            advertisedServiceUuidStrings = listOf("8A580001-2FE8-4796-9267-B87A2B0C8234"),
        )

        assertFalse(decision.shouldConnect)
        assertEquals(WhoopGattServiceFamily.MONUMENT, decision.unsupportedFamily)
    }

    @Test
    fun selectedServiceAdvertisementsStillConnect() {
        val decision = whoopGattScanDecision(
            selectedServiceUuidString = DeviceFamily.WHOOP4.serviceUuidString,
            advertisedServiceUuidStrings = listOf(DeviceFamily.WHOOP4.serviceUuidString),
        )

        assertTrue(decision.shouldConnect)
        assertNull(decision.unsupportedFamily)
    }

    @Test
    fun emptyAdvertisementServiceListPreservesLegacyConnectPath() {
        val decision = whoopGattScanDecision(
            selectedServiceUuidString = DeviceFamily.WHOOP4.serviceUuidString,
            advertisedServiceUuidStrings = emptyList(),
        )

        assertTrue(decision.shouldConnect)
        assertNull(decision.unsupportedFamily)
    }
}
