package com.noop.ble

import com.noop.analytics.ImuActivityFeatures
import com.noop.analytics.ImuFeatureExtractor
import com.noop.protocol.Whoop5RawImu

/**
 * Pure predicates + inline-IMU summary for the durable WHOOP 5.0/MG **high-rate deep-buffer** research
 * log (#423) — the large type-0x2F (R22) packets that carry tens-of-Hz sensor data (motion + optical)
 * rather than the 1 Hz historical rollup NOOP already decodes. Kotlin twin of the Swift
 * `PuffinDeepBufferLog` (its pure, unit-testable core); the file I/O + capture-toggle gating live in
 * [WhoopBleClient.writeWhoop5DeepBufferIfBig], mirroring the existing `whoop5-events.jsonl` writer.
 *
 * On-strap probing (#423) established that the 5/MG has no live raw-IMU stream, but it DOES bank
 * high-rate motion and ships it inside big type-0x2F buffers during the connect-time offload burst —
 * 124 B (~1 Hz record), 1244 B and 2140 B (~32 and ~59 sub-records per timestamped second). NOOP's
 * historical decoder pulls the 1 Hz gravity vector out and DISCARDS the high-rate remainder. Keeping the
 * big (>= [minBufferBytes]) type-0x2F buffers raw, in their own file, lets a byte-perfect decoder be
 * reversed offline from many (raw buffer, wall-clock) pairs across days of ordinary wear.
 */
object PuffinDeepBufferLog {

    /** WHOOP 5/MG inner-record type byte for the R22 deep packets (type 47 / 0x2F), at offset 8 (the
     *  same position [WhoopBleClient.isOffloadFrame] / the event log index). The 1 Hz rollup is also
     *  type-0x2F but small; [minBufferBytes] keeps only the high-rate buffers. */
    private const val deepTypeByte = 0x2F
    private const val innerRecordOffset = 8

    /** Skip the ~124-B ~1 Hz record; keep the 1244-/2140-B high-rate buffers. */
    private const val minBufferBytes = 1000

    /** Pure predicate: is [frame] a WHOOP 5/MG high-rate deep buffer? A reassembled frame's inner-record
     *  type byte sits at offset 8, so this needs `size > 8` before indexing. */
    fun isDeepBuffer(frame: ByteArray): Boolean =
        frame.size > innerRecordOffset &&
            frame.size >= minBufferBytes &&
            (frame[innerRecordOffset].toInt() and 0xFF) == deepTypeByte

    /** The strap's own unix-second stamp at frame offset 15 (u32 LE), or null if the frame is too short.
     *  This is the timestamp the high-rate records inside the buffer are relative to. */
    fun strapTs(frame: ByteArray): Long? {
        if (frame.size <= 18) return null
        return (frame[15].toLong() and 0xFF) or ((frame[16].toLong() and 0xFF) shl 8) or
            ((frame[17].toLong() and 0xFF) shl 16) or ((frame[18].toLong() and 0xFF) shl 24)
    }

    /** Decoded-IMU field for the JSONL line: `,"imu":{...features...}` when [frame] is the 1244-B 6-axis
     *  IMU buffer, else `""` (the 2140-B optical buffer and everything else). Pure and non-throwing — a
     *  decode miss just omits the field, so a diagnostics-only summary can never disturb the capture path.
     *  The first CALLER of [Whoop5RawImu.decode] outside its own tests. */
    fun decodedImuField(frame: ByteArray): String {
        if (frame.size != Whoop5RawImu.bufferLength) return ""
        val decoded = Whoop5RawImu.decode(frame) ?: return ""
        val f = ImuFeatureExtractor.extract(decoded.samples, decoded.sampleRateHz)
        val json = encodeFeatures(f) ?: return ""
        return ",\"imu\":$json"
    }

    /** Canonical JSON for [ImuActivityFeatures] — same keys, same declaration order as the Swift `Codable`
     *  output; `cadenceHz` is OMITTED when null (Swift's synthesized `encodeIfPresent`). Returns null if any
     *  value is non-finite (Swift's JSONEncoder throws on non-conforming floats → the field is dropped),
     *  matching parity. VALUE-parity, not byte-text-parity: a near-zero Double serializes as e.g. `5.0E-4`
     *  here vs `0.0005` from Swift's JSONEncoder — both valid JSON that parse to the identical number (this
     *  is a research JSONL the analysis tool parses, not a byte-stable stored value crossing `.noopbak`). */
    private fun encodeFeatures(f: ImuActivityFeatures): String? {
        val nums = listOfNotNull(f.accelEnergyG, f.gyroEnergyDps, f.jerkRms, f.cadenceHz, f.cadenceStrength)
        if (nums.any { !it.isFinite() }) return null
        return buildString {
            append('{')
            append("\"accelEnergyG\":").append(f.accelEnergyG).append(',')
            append("\"gyroEnergyDps\":").append(f.gyroEnergyDps).append(',')
            append("\"jerkRms\":").append(f.jerkRms)
            if (f.cadenceHz != null) { append(",\"cadenceHz\":").append(f.cadenceHz) }
            append(",\"cadenceStrength\":").append(f.cadenceStrength)
            append(",\"sampleCount\":").append(f.sampleCount)
            append('}')
        }
    }
}
