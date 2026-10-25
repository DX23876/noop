package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Parity with Swift `LabBookFormat` (StrandTests/LabBookFormatTests.swift). The expected lists are the
 * verbatim stdout of the Swift helpers compiled standalone (`swiftc -O twin.swift main.swift`) over
 * [inputs], so the two platforms print the same string for every value.
 */
class LabValueFormatTest {
    private val inputs = listOf(
        0.27, 1.020, 1.02, 140.0, 0.0, -0.0, -0.0001, 0.0004, 0.0005, 1.0005, 0.0625, 2.675, 12.5, 0.125,
        3.14159, 1234567.891, 5.2, 0.1, 0.30000000000000004, 99.9995, -3.25, 1e-7,
    )

    @Test
    fun customMarkerKeepsItsOwnPrecision() {
        assertEquals("0.27", LabValueFormat.value(0.27, "custom_plateletcrit"))
        assertEquals("1.02", LabValueFormat.value(1.020, "custom_urine_specific_gravity"))
        assertEquals("140", LabValueFormat.value(140.0, "custom_platelets"))
    }

    @Test
    fun plainMatchesSwiftOracle() {
        val expected = listOf(
            "0.27", "1.02", "1.02", "140", "0", "0", "0", "0", "0.001", "1", "0.062", "2.675", "12.5", "0.125",
            "3.142", "1234567.891", "5.2", "0.1", "0.3", "99.999", "-3.25", "0",
        )
        assertEquals(expected, inputs.map { LabValueFormat.plain(it) })
        assertEquals("—", LabValueFormat.plain(Double.NaN))
        assertEquals("—", LabValueFormat.plain(Double.POSITIVE_INFINITY))
    }

    @Test
    fun catalogDecimalsMatchSwiftOracle() {
        // ferritin = 0 decimals, weight = 1, tsh = 2 (MarkerCatalog.builtIn).
        val expected0 = listOf(
            "0", "1", "1", "140", "0", "0", "0", "0", "0", "1", "0", "3", "13", "0", "3", "1234568", "5", "0",
            "0", "100", "-3", "0",
        )
        val expected1 = listOf(
            "0.3", "1.0", "1.0", "140.0", "0.0", "-0.0", "-0.0", "0.0", "0.0", "1.0", "0.1", "2.7", "12.5", "0.1",
            "3.1", "1234567.9", "5.2", "0.1", "0.3", "100.0", "-3.2", "0.0",
        )
        val expected2 = listOf(
            "0.27", "1.02", "1.02", "140.00", "0.00", "-0.00", "-0.00", "0.00", "0.00", "1.00", "0.06", "2.67",
            "12.50", "0.12", "3.14", "1234567.89", "5.20", "0.10", "0.30", "100.00", "-3.25", "0.00",
        )
        assertEquals(expected0, inputs.map { LabValueFormat.value(it, "ferritin") })
        assertEquals(expected1, inputs.map { LabValueFormat.value(it, "weight") })
        assertEquals(expected2, inputs.map { LabValueFormat.value(it, "tsh") })
    }
}
