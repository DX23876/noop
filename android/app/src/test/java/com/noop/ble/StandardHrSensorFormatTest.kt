package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Contract for the additive in-workout sensor-readout formatters ([StandardHrSource.formatSpeedKmh] /
 * [formatCadence] / [formatPowerWatts]). These are pure (no android.bluetooth) and faithful twins of the
 * Swift `LiveState.formatSensor*`, so the in-workout speed/cadence/power readout reads identically on both
 * platforms.
 *
 * HONEST DATA contract: a field that's absent / negative / non-finite formats to null so the UI hides that
 * tile rather than show a fabricated value. Present values use the sensor's native units (no conversion
 * guessing) — speed km/h to one decimal, cadence per-minute rounded, power whole watts.
 */
class StandardHrSensorFormatTest {

    // MARK: - Speed (km/h, one decimal)

    @Test fun speedFormatsToOneDecimal() {
        assertEquals("12.3", StandardHrSource.formatSpeedKmh(12.34))
        assertEquals("0.0", StandardHrSource.formatSpeedKmh(0.0))
        assertEquals("36.0", StandardHrSource.formatSpeedKmh(36.0))
    }

    @Test fun speedRoundsHalfUp() {
        assertEquals("8.6", StandardHrSource.formatSpeedKmh(8.55))
    }

    @Test fun speedNullForAbsentNegativeOrNonFinite() {
        assertNull(StandardHrSource.formatSpeedKmh(null))
        assertNull(StandardHrSource.formatSpeedKmh(-1.0))
        assertNull(StandardHrSource.formatSpeedKmh(Double.NaN))
        assertNull(StandardHrSource.formatSpeedKmh(Double.POSITIVE_INFINITY))
    }

    // MARK: - Cadence (per-minute, rounded whole)

    @Test fun cadenceRoundsToWhole() {
        assertEquals("90", StandardHrSource.formatCadence(90.0))
        assertEquals("90", StandardHrSource.formatCadence(89.6))
        assertEquals("89", StandardHrSource.formatCadence(89.4))
        assertEquals("180", StandardHrSource.formatCadence(180.0))   // running steps/min
    }

    @Test fun cadenceNullForAbsentNegativeOrNonFinite() {
        assertNull(StandardHrSource.formatCadence(null))
        assertNull(StandardHrSource.formatCadence(-0.5))
        assertNull(StandardHrSource.formatCadence(Double.NaN))
    }

    // MARK: - Power (whole watts)

    @Test fun powerFormatsWholeWatts() {
        assertEquals("0", StandardHrSource.formatPowerWatts(0))
        assertEquals("245", StandardHrSource.formatPowerWatts(245))
    }

    @Test fun powerNullForAbsentOrNegative() {
        assertNull(StandardHrSource.formatPowerWatts(null))
        // A sint16 power meter CAN report a transient negative (coasting); we hide it rather than show a
        // confusing "-1 W" beside the others — honest "not a meaningful instantaneous value right now".
        assertNull(StandardHrSource.formatPowerWatts(-1))
    }
}
