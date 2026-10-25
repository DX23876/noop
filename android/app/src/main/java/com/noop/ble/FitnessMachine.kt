package com.noop.ble

/**
 * FTMS (Fitness Machine Service, 0x1826) pure decoders + the standard Battery Level (0x2A19) parser.
 *
 * Faithful Kotlin twin of WhoopProtocol/FTMSDecode.swift. Spec-deterministic field parsing for the four
 * machine-data characteristics NOOP reads live:
 *   - Treadmill Data     0x2ACD
 *   - Cross Trainer Data 0x2ACE
 *   - Rower Data         0x2AD1
 *   - Indoor Bike Data   0x2AD2
 *
 * Each characteristic begins with a little-endian flags field whose bits gate which fields follow, in a
 * FIXED spec order. We decode the flag-gated fields we surface (speed, cadence, power, distance, total
 * energy, heart rate, elapsed time) and IGNORE the rest by advancing the cursor by their spec width, so
 * an unrecognised optional field never desynchronises the ones after it.
 *
 * SECURITY / ROBUSTNESS: the byte buffer is UNTRUSTED BLE input. Every field read is bounds-checked
 * against the buffer length; a truncated/malformed packet yields the fields decoded so far (never a
 * crash, never a read past the end) — mirroring [StandardHeartRate.parse]'s bounds discipline.
 *
 * Pure (no android.bluetooth) → unit-tested on the JVM against byte fixtures built from the FTMS spec.
 *
 * Reference: Bluetooth SIG "Fitness Machine Service" 1.0 + the GATT Specification Supplement field
 * tables. NOOP's own clean re-implementation of the public spec.
 */
object FitnessMachine {

    /** Which FTMS machine, identified by which machine-data characteristic it streams. */
    enum class MachineKind(val uuid16: String, val displayName: String) {
        TREADMILL("2ACD", "Treadmill"),
        INDOOR_BIKE("2AD2", "Indoor Bike"),
        ROWER("2AD1", "Rower"),
        CROSS_TRAINER("2ACE", "Cross Trainer"),
    }

    /**
     * A single decoded FTMS machine-data notification. Every field is nullable — a machine advertises
     * only a subset, and a truncated packet decodes only what fit. Units are the spec's resolved units.
     */
    data class Reading(
        val kind: MachineKind,
        /** Instantaneous speed in km/h. */
        val speedKmh: Double? = null,
        /** Cadence: steps/min (treadmill/cross-trainer), rpm (indoor bike), strokes/min (rower). */
        val cadence: Double? = null,
        /** Instantaneous power in watts (signed). */
        val powerWatts: Int? = null,
        /** Total distance this session, in metres. */
        val distanceM: Int? = null,
        /** Total energy this session, in kilocalories. */
        val totalEnergyKcal: Int? = null,
        /** Heart rate in bpm, if the machine reports it. */
        val heartRate: Int? = null,
        /** Elapsed session time in seconds. */
        val elapsedTimeSec: Int? = null,
    )

    /** A forward cursor over the byte buffer; reads advance only on success (bounds-checked). */
    private class Reader(val bytes: ByteArray) {
        var idx = 0
        fun u8(): Int? {
            if (idx >= bytes.size) return null
            return (bytes[idx++].toInt() and 0xFF)
        }
        fun u16(): Int? {
            if (idx + 1 >= bytes.size) return null
            val v = (bytes[idx].toInt() and 0xFF) or ((bytes[idx + 1].toInt() and 0xFF) shl 8)
            idx += 2
            return v
        }
        /** Signed 16-bit (two's complement) — FTMS power is sint16. */
        fun s16(): Int? {
            val raw = u16() ?: return null
            return if (raw >= 0x8000) raw - 0x10000 else raw
        }
        fun u24(): Int? {
            if (idx + 2 >= bytes.size) return null
            val v = (bytes[idx].toInt() and 0xFF) or
                ((bytes[idx + 1].toInt() and 0xFF) shl 8) or
                ((bytes[idx + 2].toInt() and 0xFF) shl 16)
            idx += 3
            return v
        }
        /** Skip n bytes (an optional field we don't surface), clamped so it never runs past the end. */
        fun skip(n: Int) { idx = minOf(bytes.size, idx + n) }
    }

    // MARK: - Treadmill Data (0x2ACD)
    fun treadmill(data: ByteArray): Reading? {
        val r = Reader(data)
        val flags = r.u16() ?: return null
        var speed: Double? = null
        var distance: Int? = null
        var energy: Int? = null
        var hr: Int? = null
        var elapsed: Int? = null

        if (flags and 0x0001 == 0) r.u16()?.let { speed = it * 0.01 }  // Inst. Speed (absent if More Data)
        if (flags and 0x0002 != 0) r.u16()                            // Average Speed
        if (flags and 0x0004 != 0) r.u24()?.let { distance = it }     // Total Distance
        if (flags and 0x0008 != 0) r.skip(4)                          // Inclination + Ramp Angle
        if (flags and 0x0010 != 0) r.skip(4)                          // Pos + Neg Elevation Gain
        if (flags and 0x0020 != 0) r.u8()                             // Instantaneous Pace
        if (flags and 0x0040 != 0) r.u8()                             // Average Pace
        if (flags and 0x0080 != 0) {                                  // Total Energy block
            r.u16()?.let { energy = it }                              // Total Energy (kcal)
            r.u16(); r.u8()                                           // per-hour + per-min
        }
        if (flags and 0x0100 != 0) r.u8()?.let { hr = it }            // Heart Rate
        if (flags and 0x0200 != 0) r.u8()                             // Metabolic Equivalent
        if (flags and 0x0400 != 0) r.u16()?.let { elapsed = it }      // Elapsed Time
        return Reading(MachineKind.TREADMILL, speedKmh = speed, distanceM = distance,
            totalEnergyKcal = energy, heartRate = hr, elapsedTimeSec = elapsed)
    }

    // MARK: - Indoor Bike Data (0x2AD2)
    fun indoorBike(data: ByteArray): Reading? {
        val r = Reader(data)
        val flags = r.u16() ?: return null
        var speed: Double? = null
        var cadence: Double? = null
        var power: Int? = null
        var distance: Int? = null
        var energy: Int? = null
        var hr: Int? = null
        var elapsed: Int? = null

        if (flags and 0x0001 == 0) r.u16()?.let { speed = it * 0.01 } // Inst. Speed
        if (flags and 0x0002 != 0) r.u16()                           // Average Speed
        if (flags and 0x0004 != 0) r.u16()?.let { cadence = it * 0.5 } // Inst. Cadence (0.5 rpm)
        if (flags and 0x0008 != 0) r.u16()                           // Average Cadence
        if (flags and 0x0010 != 0) r.u24()?.let { distance = it }    // Total Distance
        if (flags and 0x0020 != 0) r.u16()                           // Resistance Level
        if (flags and 0x0040 != 0) r.s16()?.let { power = it }       // Inst. Power
        if (flags and 0x0080 != 0) r.s16()                           // Average Power
        if (flags and 0x0100 != 0) { r.u16()?.let { energy = it }; r.u16(); r.u8() } // Total Energy
        if (flags and 0x0200 != 0) r.u8()?.let { hr = it }           // Heart Rate
        if (flags and 0x0400 != 0) r.u8()                            // Metabolic Equivalent
        if (flags and 0x0800 != 0) r.u16()?.let { elapsed = it }     // Elapsed Time
        return Reading(MachineKind.INDOOR_BIKE, speedKmh = speed, cadence = cadence, powerWatts = power,
            distanceM = distance, totalEnergyKcal = energy, heartRate = hr, elapsedTimeSec = elapsed)
    }

    // MARK: - Rower Data (0x2AD1)
    fun rower(data: ByteArray): Reading? {
        val r = Reader(data)
        val flags = r.u16() ?: return null
        var cadence: Double? = null
        var power: Int? = null
        var distance: Int? = null
        var energy: Int? = null
        var hr: Int? = null
        var elapsed: Int? = null

        if (flags and 0x0001 == 0) {                                 // Stroke Rate + Stroke Count
            r.u8()?.let { cadence = it * 0.5 }                       // 0.5 stroke/min
            r.u16()                                                  // Stroke Count
        }
        if (flags and 0x0002 != 0) r.u8()                           // Average Stroke Rate
        if (flags and 0x0004 != 0) r.u24()?.let { distance = it }   // Total Distance
        if (flags and 0x0008 != 0) r.u16()                          // Inst. Pace
        if (flags and 0x0010 != 0) r.u16()                          // Average Pace
        if (flags and 0x0020 != 0) r.s16()?.let { power = it }      // Inst. Power
        if (flags and 0x0040 != 0) r.s16()                          // Average Power
        if (flags and 0x0080 != 0) r.s16()                          // Resistance Level
        if (flags and 0x0100 != 0) { r.u16()?.let { energy = it }; r.u16(); r.u8() } // Total Energy
        if (flags and 0x0200 != 0) r.u8()?.let { hr = it }          // Heart Rate
        if (flags and 0x0400 != 0) r.u8()                           // Metabolic Equivalent
        if (flags and 0x0800 != 0) r.u16()?.let { elapsed = it }    // Elapsed Time
        return Reading(MachineKind.ROWER, cadence = cadence, powerWatts = power, distanceM = distance,
            totalEnergyKcal = energy, heartRate = hr, elapsedTimeSec = elapsed)
    }

    // MARK: - Cross Trainer Data (0x2ACE) — 24-bit flags (u16 + u8)
    fun crossTrainer(data: ByteArray): Reading? {
        val r = Reader(data)
        val lo = r.u16() ?: return null
        val hi = r.u8() ?: return null
        val flags = lo or (hi shl 16)
        var speed: Double? = null
        var cadence: Double? = null
        var power: Int? = null
        var distance: Int? = null
        var energy: Int? = null
        var hr: Int? = null
        var elapsed: Int? = null

        if (flags and 0x000001 == 0) r.u16()?.let { speed = it * 0.01 } // Inst. Speed
        if (flags and 0x000002 != 0) r.u16()                         // Average Speed
        if (flags and 0x000004 != 0) r.u24()?.let { distance = it }  // Total Distance
        if (flags and 0x000008 != 0) {                               // Step Count block
            r.u16()?.let { cadence = it.toDouble() }                 // Step Per Minute
            r.u16()                                                  // Average Step Rate
        }
        if (flags and 0x000010 != 0) r.u16()                         // Stride Count
        if (flags and 0x000020 != 0) r.skip(4)                       // Pos + Neg Elevation Gain
        if (flags and 0x000040 != 0) r.skip(4)                       // Inclination + Ramp Angle
        if (flags and 0x000080 != 0) r.s16()                         // Resistance Level
        if (flags and 0x000100 != 0) r.s16()?.let { power = it }     // Inst. Power
        if (flags and 0x000200 != 0) r.s16()                         // Average Power
        if (flags and 0x000400 != 0) { r.u16()?.let { energy = it }; r.u16(); r.u8() } // Total Energy
        if (flags and 0x000800 != 0) r.u8()?.let { hr = it }         // Heart Rate
        if (flags and 0x001000 != 0) r.u8()                          // Metabolic Equivalent
        if (flags and 0x002000 != 0) r.u16()?.let { elapsed = it }   // Elapsed Time
        return Reading(MachineKind.CROSS_TRAINER, speedKmh = speed, cadence = cadence, powerWatts = power,
            distanceM = distance, totalEnergyKcal = energy, heartRate = hr, elapsedTimeSec = elapsed)
    }

    /** Decode by the 16-bit characteristic UUID short form (case-insensitive); null for unknown/empty. */
    fun decode(uuid16: String, data: ByteArray): Reading? = when (uuid16.uppercase()) {
        "2ACD" -> treadmill(data)
        "2AD2" -> indoorBike(data)
        "2AD1" -> rower(data)
        "2ACE" -> crossTrainer(data)
        else -> null
    }
}

/**
 * Pure parser for the standard BLE Battery Level characteristic (0x2A19): a single u8 percent, 0–100.
 * Values above 100 are clamped; an empty buffer yields null. Faithful twin of Swift `StandardBattery`.
 */
object StandardBattery {
    fun parse(data: ByteArray): Int? {
        if (data.isEmpty()) return null
        return minOf(100, data[0].toInt() and 0xFF)
    }
}
