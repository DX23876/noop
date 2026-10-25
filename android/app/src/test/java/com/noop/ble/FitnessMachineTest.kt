package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Spec-deterministic FTMS field-decode contract — the JVM twin of WhoopProtocol's FTMSDecodeTests.
 * Fixtures are built BYTE-BY-BYTE from the Bluetooth SIG Fitness Machine Service field tables (not a
 * real capture), asserting the exact flag→field mapping + fixed-point→unit scaling for the fields NOOP
 * surfaces. Pure decode → no android.bluetooth.
 */
class FitnessMachineTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { (v[it] and 0xFF).toByte() }
    private fun le16(v: Int): IntArray = intArrayOf(v and 0xFF, (v shr 8) and 0xFF)
    private fun le24(v: Int): IntArray = intArrayOf(v and 0xFF, (v shr 8) and 0xFF, (v shr 16) and 0xFF)
    private fun pack(vararg parts: IntArray): ByteArray {
        val all = parts.flatMap { it.toList() }
        return ByteArray(all.size) { (all[it] and 0xFF).toByte() }
    }

    // MARK: - Treadmill (0x2ACD)

    @Test
    fun treadmillSpeedDistanceEnergyHrElapsed() {
        // flags: speed present, Total Distance (bit2), Total Energy (bit7), HR (bit8), Elapsed (bit10).
        val flags = 0x0004 or 0x0080 or 0x0100 or 0x0400
        val data = pack(
            le16(flags),
            le16(853),                 // 8.53 km/h
            le24(1250),                // 1250 m
            le16(42), le16(300), intArrayOf(5),  // energy 42 kcal + per-hour + per-min
            intArrayOf(131),           // HR
            le16(615),                 // elapsed 615 s
        )
        val r = FitnessMachine.treadmill(data)!!
        assertEquals(FitnessMachine.MachineKind.TREADMILL, r.kind)
        assertEquals(8.53, r.speedKmh!!, 0.0001)
        assertEquals(1250, r.distanceM)
        assertEquals(42, r.totalEnergyKcal)
        assertEquals(131, r.heartRate)
        assertEquals(615, r.elapsedTimeSec)
        assertNull(r.powerWatts)
        assertNull(r.cadence)
    }

    @Test
    fun treadmillMoreDataBitOmitsSpeed() {
        val flags = 0x0001 or 0x0100
        val r = FitnessMachine.treadmill(pack(le16(flags), intArrayOf(99)))!!
        assertNull(r.speedKmh)
        assertEquals(99, r.heartRate)
    }

    @Test
    fun treadmillInclinationAndElevationAreSkippedNotMisread() {
        // More Data (bit0) set → speed ABSENT; inclination (bit3) + elevation (bit4) precede HR (bit8).
        val flags = 0x0001 or 0x0008 or 0x0010 or 0x0100
        val data = pack(
            le16(flags),
            le16(0x1234), le16(0x5678),  // inclination + ramp
            le16(0x0010), le16(0x0000),  // elevation pos + neg
            intArrayOf(77),              // HR
        )
        val r = FitnessMachine.treadmill(data)!!
        assertNull(r.speedKmh)
        assertEquals(77, r.heartRate)
    }

    // MARK: - Indoor Bike (0x2AD2)

    @Test
    fun indoorBikeSpeedCadencePowerEnergyHr() {
        val flags = 0x0004 or 0x0040 or 0x0100 or 0x0200
        val data = pack(
            le16(flags),
            le16(3000),                // 30.00 km/h
            le16(180),                 // cadence raw 180 → 90.0 rpm
            le16(245),                 // power 245 W
            le16(73), le16(600), intArrayOf(10), // energy 73 kcal + per-hour + per-min
            intArrayOf(142),           // HR
        )
        val r = FitnessMachine.indoorBike(data)!!
        assertEquals(30.0, r.speedKmh!!, 0.0001)
        assertEquals(90.0, r.cadence!!, 0.0001)
        assertEquals(245, r.powerWatts)
        assertEquals(73, r.totalEnergyKcal)
        assertEquals(142, r.heartRate)
    }

    @Test
    fun indoorBikeNegativePowerIsSigned() {
        // More Data (bit0) set → speed absent; Inst. Power (bit6) sint16 0xFFFF = -1 W.
        val r = FitnessMachine.indoorBike(pack(le16(0x0001 or 0x0040), le16(0xFFFF)))!!
        assertNull(r.speedKmh)
        assertEquals(-1, r.powerWatts)
    }

    // MARK: - Rower (0x2AD1)

    @Test
    fun rowerStrokeRateDistancePowerEnergyHr() {
        val flags = 0x0004 or 0x0020 or 0x0100 or 0x0200
        val data = pack(
            le16(flags),
            intArrayOf(60),            // stroke rate raw 60 → 30.0 /min
            le16(412),                 // stroke count (skipped)
            le24(503),                 // distance 503 m
            le16(160),                 // power 160 W
            le16(58), le16(420), intArrayOf(7), // energy 58 kcal + per-hour + per-min
            intArrayOf(128),           // HR
        )
        val r = FitnessMachine.rower(data)!!
        assertEquals(30.0, r.cadence!!, 0.0001)
        assertEquals(503, r.distanceM)
        assertEquals(160, r.powerWatts)
        assertEquals(58, r.totalEnergyKcal)
        assertEquals(128, r.heartRate)
    }

    @Test
    fun rowerMoreDataBitOmitsStroke() {
        val flags = 0x0001 or 0x0004
        val r = FitnessMachine.rower(pack(le16(flags), le24(1000)))!!
        assertNull(r.cadence)
        assertEquals(1000, r.distanceM)
    }

    // MARK: - Cross Trainer (0x2ACE) — 24-bit flags

    @Test
    fun crossTrainerStepRateDistancePowerHr() {
        val flags = 0x000004 or 0x000008 or 0x000100 or 0x000800
        val data = pack(
            le16(flags and 0xFFFF), intArrayOf((flags shr 16) and 0xFF),
            le16(450),                 // 4.50 km/h
            le24(880),                 // 880 m
            le16(56), le16(54),        // step/min 56 (cadence) + avg step rate (skipped)
            le16(112),                 // power 112 W
            intArrayOf(120),           // HR
        )
        val r = FitnessMachine.crossTrainer(data)!!
        assertEquals(FitnessMachine.MachineKind.CROSS_TRAINER, r.kind)
        assertEquals(4.5, r.speedKmh!!, 0.0001)
        assertEquals(880, r.distanceM)
        assertEquals(56.0, r.cadence!!, 0.0001)
        assertEquals(112, r.powerWatts)
        assertEquals(120, r.heartRate)
    }

    // MARK: - Robustness over UNTRUSTED / malformed input

    @Test
    fun emptyAndShortBuffersNeverCrash() {
        assertNull(FitnessMachine.treadmill(ByteArray(0)))
        assertNull(FitnessMachine.indoorBike(bytes(0x04)))
        assertNull(FitnessMachine.crossTrainer(bytes(0x00, 0x00)))
        // flags=0x0000 → speed present but only one of its two bytes follow → not consumed, no over-read.
        val truncated = FitnessMachine.indoorBike(bytes(0x00, 0x00, 0xB8))
        assertNotNull(truncated)
        assertNull(truncated!!.speedKmh)
    }

    @Test
    fun hugeBufferIsBounded() {
        // More Data (bit0) set → speed absent, so HR (bit8) is the only declared field; junk ignored.
        val head = le16(0x0001 or 0x0100).plus(88)     // More-Data + HR flag, HR=88
        val junk = IntArray(5000) { 0xAB }
        val r = FitnessMachine.treadmill(pack(head, junk))!!
        assertEquals(88, r.heartRate)
    }

    @Test
    fun decodeByUuidDispatch() {
        assertEquals(FitnessMachine.MachineKind.TREADMILL,
            FitnessMachine.decode("2acd", pack(le16(0x0101), intArrayOf(70)))?.kind)
        assertEquals(FitnessMachine.MachineKind.INDOOR_BIKE,
            FitnessMachine.decode("2AD2", pack(le16(0x0201), intArrayOf(70)))?.kind)
        assertNull(FitnessMachine.decode("1234", bytes(0x00, 0x00)))
    }

    // MARK: - Battery (0x2A19)

    @Test
    fun batteryPercentParse() {
        assertEquals(72, StandardBattery.parse(bytes(72)))
        assertEquals(0, StandardBattery.parse(bytes(0)))
        assertEquals(100, StandardBattery.parse(bytes(100)))
    }

    @Test
    fun batteryClampsAbove100AndRejectsEmpty() {
        assertEquals(100, StandardBattery.parse(bytes(200)))
        assertNull(StandardBattery.parse(ByteArray(0)))
    }
}
