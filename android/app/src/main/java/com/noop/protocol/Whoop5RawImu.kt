package com.noop.protocol

// Whoop5RawImu.kt — decoder for the WHOOP 5.0/MG raw 6-axis IMU offload buffer (#423). Kotlin twin of
// WhoopProtocol/Whoop5RawImu.swift — byte-identical layout, scales, and gating (parity contract).
//
// The 5/MG ships a 1244-byte buffer during the connect-time offload burst that carries a full second
// of raw inertial data: 100 accelerometer samples + 100 gyroscope samples, stored COLUMNAR (all ax,
// then all ay, then all az; likewise the gyro), i16 little-endian. This is the SAME shape the WHOOP
// app captures (Asherlc/dofek docs/whoop-ble-protocol.md type-0x2B raw packet) and the same columnar
// convention as the 4.0's 1917 REALTIME_RAW_DATA variant.
//
// IMPORTANT: the 5/MG's *live* raw-IMU stream is firmware-refused (TOGGLE_IMU_MODE / cmd 106 acks but
// never streams), but the OFFLOAD buffer carries full accel AND gyro — so 100 Hz 6-axis IMU IS
// obtainable on the 5.0 via the historical path.
//
// Frame layout (reassembled BLE frame = 8-byte puffin envelope + payload; offsets are FRAME-absolute):
//   @15  u32 LE   strap unix seconds for this 1-second frame
//   @24  u16 LE   countA (accelerometer sample count, = 100)
//   @28  100×i16  ax   @228 100×i16 ay   @428 100×i16 az     scale 1/4096 g/LSB
//   @630 u16 LE   countB (gyroscope sample count, = 100)
//   @640 100×i16  gx   @840 100×i16 gy   @1040 100×i16 gz    scale 2000/32768 (°/s)/LSB (±2000 dps)
//
// VALIDATED on 1423 buffers from a real 5.0 (fw 50.40.1.0): accel magnitude is a 1.01 g gravity shell
// (100 % of samples within ±15 % of the median; 4117 ± 11 LSB across 200 s), gyro near zero at rest,
// spikes in motion, correlates 0.79 with accel motion. Pure/deterministic; no I/O, no strap.

/** One raw IMU sample: 3-axis accelerometer (g) + 3-axis gyroscope (deg/s). */
data class RawImuSample(
    val ax: Double, val ay: Double, val az: Double,   // g
    val gx: Double, val gy: Double, val gz: Double,   // deg/s
)

/** One decoded 5/MG raw-IMU buffer: a second of 6-axis samples with the strap's base timestamp. */
data class Whoop5ImuFrame(
    val baseTs: Long,           // strap unix seconds for the frame (Swift `Int` = 64-bit; holds full u32)
    val sampleRateHz: Int,      // 100
    val samples: List<RawImuSample>,
) {
    /** Wall-clock unix seconds for sample [i] (samples are evenly spaced across the 1-second frame). */
    fun ts(i: Int): Double = baseTs.toDouble() + i.toDouble() / maxOf(1, sampleRateHz).toDouble()
}

object Whoop5RawImu {

    const val bufferLength = 1244
    const val sampleCount = 100
    const val accelScale = 1.0 / 4096.0            // g per LSB (WHOOP accel scale)
    const val gyroScale = 2000.0 / 32768.0         // deg/s per LSB (±2000 dps, ~16.4 LSB/dps)

    // FRAME-absolute offsets (8-byte puffin envelope + payload).
    private const val tsOff = 15
    private const val countAOff = 24
    private const val axOff = 28
    private const val ayOff = 228
    private const val azOff = 428
    private const val countBOff = 630
    private const val gxOff = 640
    private const val gyOff = 840
    private const val gzOff = 1040

    /** Decode a raw-IMU buffer, or null if it isn't one. Gates on the exact length + the two in-packet
     *  sample counts (=100) rather than the type byte, so it can't misfire on a same-type non-IMU frame. */
    fun decode(f: ByteArray): Whoop5ImuFrame? {
        if (f.size != bufferLength) return null   // exact length, matching Swift's `f.count == bufferLength` (#546)
        if (u16(f, countAOff) != sampleCount || u16(f, countBOff) != sampleCount) return null
        if (gzOff + 2 * sampleCount > f.size) return null
        val baseTs = u32(f, tsOff)   // full u32 (matches Swift `Int(u32(...))` on 64-bit — no truncation)
        val samples = ArrayList<RawImuSample>(sampleCount)
        for (i in 0 until sampleCount) {
            val o = 2 * i
            samples.add(
                RawImuSample(
                    ax = i16(f, axOff + o) * accelScale,
                    ay = i16(f, ayOff + o) * accelScale,
                    az = i16(f, azOff + o) * accelScale,
                    gx = i16(f, gxOff + o) * gyroScale,
                    gy = i16(f, gyOff + o) * gyroScale,
                    gz = i16(f, gzOff + o) * gyroScale,
                ),
            )
        }
        return Whoop5ImuFrame(baseTs = baseTs, sampleRateHz = sampleCount, samples = samples)
    }

    /** The raw i16 columns exactly as they sit on the wire — [ax×100, ay×100, az×100, gx×100, gy×100,
     *  gz×100] — for faithful, compact storage (#423). Same length + sample-count gate and same offsets as
     *  [decode]; null if [f] isn't a valid IMU buffer. The scales ([accelScale]/[gyroScale]) stay documented
     *  constants applied at read time, so nothing lossy is baked into the stored bytes. */
    fun rawColumns(f: ByteArray): ShortArray? {
        if (f.size != bufferLength) return null
        if (u16(f, countAOff) != sampleCount || u16(f, countBOff) != sampleCount) return null
        if (gzOff + 2 * sampleCount > f.size) return null
        val cols = intArrayOf(axOff, ayOff, azOff, gxOff, gyOff, gzOff)
        val out = ShortArray(6 * sampleCount)
        for (c in 0 until 6) {
            for (i in 0 until sampleCount) out[c * sampleCount + i] = i16(f, cols[c] + 2 * i).toShort()
        }
        return out
    }

    // Little-endian readers (frame-absolute).
    private fun u16(f: ByteArray, o: Int): Int =
        (f[o].toInt() and 0xFF) or ((f[o + 1].toInt() and 0xFF) shl 8)

    private fun u32(f: ByteArray, o: Int): Long =
        (f[o].toLong() and 0xFF) or ((f[o + 1].toLong() and 0xFF) shl 8) or
            ((f[o + 2].toLong() and 0xFF) shl 16) or ((f[o + 3].toLong() and 0xFF) shl 24)

    private fun i16(f: ByteArray, o: Int): Int {
        val v = u16(f, o); return if (v >= 32768) v - 65536 else v
    }
}
