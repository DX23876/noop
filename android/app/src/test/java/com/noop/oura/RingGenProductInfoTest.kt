package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #772 (Kotlin twin of Swift's RingGenProductInfoTests): generation detection must NOT come from a stray
 * digit in the advertised name (a factory-reset ring advertises its serial there); the authoritative
 * generation comes from the GetProductInfo hardware id.
 */
class RingGenProductInfoTest {

    @Test fun recogniseExplicitGenToken() {
        assertEquals(OuraRingGen.GEN3, OuraRingGen.recognise("Oura Ring Gen3"))
        assertEquals(OuraRingGen.GEN4, OuraRingGen.recognise("Oura Ring 4"))
        assertEquals(OuraRingGen.GEN5, OuraRingGen.recognise("OURA RING GEN5"))
        assertEquals(OuraRingGen.GEN3, OuraRingGen.recognise("Oura Horizon"))
    }

    @Test fun recogniseSerialNameYieldsNull() {
        assertNull(OuraRingGen.recognise("Oura 2H3B2405003655"))  // the on-device Gen3 serial whose "5" was mis-read
        assertNull(OuraRingGen.recognise("Oura 9F5A"))
    }

    @Test fun recogniseNonOuraNameYieldsNull() {
        assertNull(OuraRingGen.recognise("WHOOP 5.0"))
        assertNull(OuraRingGen.recognise(null))
    }

    @Test fun fromHardwareIdKnownAndSuffix() {
        assertEquals(OuraRingGen.GEN3, OuraRingGen.fromHardwareId("BLB_03"))  // validated on-device
        assertEquals(OuraRingGen.GEN4, OuraRingGen.fromHardwareId("BLB_04"))
        assertEquals(OuraRingGen.GEN5, OuraRingGen.fromHardwareId("BLB_05"))
    }

    @Test fun fromHardwareIdUnrecognisedYieldsNull() {
        assertNull(OuraRingGen.fromHardwareId("2H3B2405003655"))  // a serial, no "_NN" gen marker
        assertNull(OuraRingGen.fromHardwareId("BLB_09"))          // unknown generation, never a guess
        assertNull(OuraRingGen.fromHardwareId("BLB_"))
        assertNull(OuraRingGen.fromHardwareId(""))
    }

    @Test fun productInfoStringDecodesSerialAndHardware() {
        val serial = intArrayOf(0x00, 0x32, 0x48, 0x33, 0x42, 0x32, 0x34, 0x30, 0x35, 0x30, 0x30, 0x33, 0x36, 0x35, 0x35, 0x00, 0x00)
        assertEquals("2H3B2405003655", OuraDecoders.productInfoString(serial))
        val hardware = intArrayOf(0x00, 0x42, 0x4c, 0x42, 0x5f, 0x30, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
        assertEquals("BLB_03", OuraDecoders.productInfoString(hardware))
    }

    @Test fun productInfoStringEmptyOrStatusOnly() {
        assertNull(OuraDecoders.productInfoString(intArrayOf()))
        assertNull(OuraDecoders.productInfoString(intArrayOf(0x00)))
        assertNull(OuraDecoders.productInfoString(intArrayOf(0x00, 0x00)))
    }

    @Test fun hardwareReplyResolvesGenSerialDoesNot() {
        val hw = intArrayOf(0x00, 0x42, 0x4c, 0x42, 0x5f, 0x30, 0x33, 0x00)
        val serial = intArrayOf(0x00, 0x32, 0x48, 0x33, 0x42, 0x32, 0x34, 0x30, 0x35, 0x30, 0x30, 0x33, 0x36, 0x35, 0x35)
        assertEquals(OuraRingGen.GEN3, OuraDecoders.productInfoString(hw)?.let { OuraRingGen.fromHardwareId(it) })
        assertNull(OuraDecoders.productInfoString(serial)?.let { OuraRingGen.fromHardwareId(it) })
    }
}
