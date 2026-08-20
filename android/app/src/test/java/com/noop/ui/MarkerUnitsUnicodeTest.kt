package com.noop.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class MarkerUnitsUnicodeTest {
    @Test fun slugCanonicalizesNfcAndNfdBeforeSlugging() {
        val expected = byteArrayOf(
            0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x5f, 0x63, 0x61, 0x66,
            0xc3.toByte(), 0xa9.toByte(), 0x5f, 0x6d, 0x61, 0x72, 0x6b, 0x65, 0x72,
        )
        assertArrayEquals(expected, MarkerUnits.slug("Caf\u00e9 Marker").toByteArray())
        assertArrayEquals(expected, MarkerUnits.slug("Cafe\u0301 Marker").toByteArray())
        assertEquals("custom_apo_b", MarkerUnits.slug("Apo B"))
    }
}
