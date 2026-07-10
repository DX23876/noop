package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Device-family-aware skin-temp raw→°C conversion (#938). Mirrors the macOS `SkinTempConversionTests`.
 *
 * The historical `skin_temp_raw` register is on DIFFERENT scales per family: a CENTIDEGREE value on the
 * 5/MG v18 (@73) but a RAW ADC on the WHOOP 4.0 v24 (@72). A single family-blind `raw/100` sent every 4.0
 * night ~8 °C low, below the 28 °C worn gate, so skin temp + the illness signal vanished (issue #938,
 * reporter dpguglielmi's 4.0 capture: worn steady raw ~826, no-contact floor ~510).
 */
class SkinTempConversionTest {

    // ── WHOOP 5/MG (unchanged: raw/100 centidegrees) ────────────────────────

    @Test
    fun whoop5IsUnchangedCentidegrees() {
        assertEquals(30.57, skinTempCelsius(3057, DeviceFamily.WHOOP5), 1e-9)
        assertEquals(22.47, skinTempCelsius(2247, DeviceFamily.WHOOP5), 1e-9)
        assertEquals(34.0, skinTempCelsius(3400, DeviceFamily.WHOOP5), 1e-9)
    }

    // ── WHOOP 4.0 v24 (raw ADC map) ─────────────────────────────────────────

    @Test
    fun whoop4WornBaselineLandsInPlausibleBand() {
        for (raw in listOf(826, 830, 845, 859, 865)) {
            val c = skinTempCelsius(raw, DeviceFamily.WHOOP4)
            assertTrue("worn 4.0 raw $raw → $c °C must clear the 28 °C worn gate", c >= 28.0)
            assertTrue("worn 4.0 raw $raw → $c °C must stay under the 42 °C worn ceiling", c <= 42.0)
        }
        assertEquals(33.0, skinTempCelsius(826, DeviceFamily.WHOOP4), 1e-9)
    }

    @Test
    fun whoop4NoContactFloorIsBelowWornGate() {
        for (raw in listOf(506, 514, 520)) {
            assertTrue("4.0 no-contact floor raw $raw must fall below the worn gate",
                skinTempCelsius(raw, DeviceFamily.WHOOP4) < 28.0)
        }
    }

    @Test
    fun whoop4AndWhoop5DifferForTheSameRaw() {
        assertNotEquals(
            skinTempCelsius(826, DeviceFamily.WHOOP4),
            skinTempCelsius(826, DeviceFamily.WHOOP5),
            1e-6,
        )
    }

    @Test
    fun whoop4SyntheticFixtureRawIsPlausible() {
        val c = skinTempCelsius(900, DeviceFamily.WHOOP4)
        assertTrue(c > 28.0)
        assertTrue(c < 42.0)
    }

    // ── per-device worn anchor (#938 second capture) ────────────────────────
    // The @72 ADC's register offset is per-device: a second real 4.0 strap shares the floor (~509) +
    // saturation (2047) but a worn band ~1100–1600 (nightly mean raw ~1290). The anchor is learned from the
    // device's OWN worn median so the worn band lands in range; the offset cancels in skinTempDevC.

    /** Odd count: the anchor is the middle in-band raw. Mirrors Swift testDeviceAnchorRawIsMedianOfInBandRaws. */
    @Test
    fun deviceAnchorRawIsMedianOfInBandRaws() {
        val raws = (1250..1350).toList() // 101 in-band values, median is the middle one (1300)
        assertEquals(101, raws.size)
        assertEquals(1300.0, Whoop4SkinTemp.deviceAnchorRaw(raws)!!, 1e-9)
    }

    /** The no-contact floor (509) and 11-bit saturation ceiling (2047) are filtered out of the anchor median
     *  entirely. Mirrors Swift testDeviceAnchorRawExcludesFloorAndSaturation. */
    @Test
    fun deviceAnchorRawExcludesFloorAndSaturation() {
        val worn = List(100) { 1290 }                          // 100 real worn raws
        val contaminated = worn + List(40) { 509 } + List(40) { 2047 } // doff floor + pegged saturation
        // Only the 100 in-band 1290s survive the band filter → median 1290 (floor/ceiling never enter the sort).
        assertEquals(1290.0, Whoop4SkinTemp.deviceAnchorRaw(contaminated)!!, 1e-9)
    }

    /** Fewer than MIN_ANCHOR_SAMPLES in-band raws → null, so the caller falls back to the global anchor
     *  (byte-identical to today). Mirrors Swift testDeviceAnchorRawNilBelowMinSamples. */
    @Test
    fun deviceAnchorRawNullBelowMinSamples() {
        assertEquals(100, Whoop4SkinTemp.MIN_ANCHOR_SAMPLES)
        assertNull(Whoop4SkinTemp.deviceAnchorRaw(List(99) { 1290 }))            // 99 < 100 → null
        assertEquals(1290.0, Whoop4SkinTemp.deviceAnchorRaw(List(100) { 1290 })!!, 1e-9) // exactly 100 → learned
    }

    /** Even count: the anchor averages the two middle in-band raws. Mirrors Swift
     *  testDeviceAnchorRawEvenCountAveragesMiddleTwo. */
    @Test
    fun deviceAnchorRawEvenCountAveragesMiddleTwo() {
        val raws = (1201..1300).toList() // 100 values, middle two are 1250 and 1251
        assertEquals(100, raws.size)
        assertEquals(1250.5, Whoop4SkinTemp.deviceAnchorRaw(raws)!!, 1e-9)
    }

    /** The learned per-device anchor raw maps to 33.0 °C, and +20 raw above it is +1.0 °C (slope 0.05); the
     *  anchor is ignored on WHOOP5. Mirrors Swift testWhoop4PerDeviceAnchorMapsToAnchorCelsius. */
    @Test
    fun whoop4PerDeviceAnchorMapsToAnchorCelsius() {
        assertEquals(33.0, skinTempCelsius(1290, DeviceFamily.WHOOP4, 1290.0), 1e-9)
        assertEquals(34.0, skinTempCelsius(1310, DeviceFamily.WHOOP4, 1290.0), 1e-9) // +20 raw = +1.0 °C
        assertEquals(34.0, skinTempCelsius(3400, DeviceFamily.WHOOP5, 1290.0), 1e-9) // WHOOP5 ignores the anchor
    }

    /** Omitting anchorRaw uses the global ANCHOR_RAW (826) → byte-identical to the pre-per-device behaviour.
     *  Mirrors Swift testWhoop4DefaultAnchorIsGlobal826. */
    @Test
    fun whoop4DefaultAnchorIsGlobal826() {
        assertEquals(
            skinTempCelsius(859, DeviceFamily.WHOOP4, Whoop4SkinTemp.ANCHOR_RAW),
            skinTempCelsius(859, DeviceFamily.WHOOP4),
            1e-12,
        )
        assertEquals(33.0, skinTempCelsius(826, DeviceFamily.WHOOP4), 1e-9)
    }
}
