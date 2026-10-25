package com.noop.oura

/**
 * Pure, deterministic encoder for ONE line of the Oura motion (0x47 motion_events) research corpus — the
 * Kotlin twin of Swift `OuraMotionDumpLine`. Byte-identical output (fixed key order), so the two platforms'
 * JSONL corpora are interchangeable.
 *
 * WHY a sidecar and not a stream/table (yet): the 0x47 decode is Tier-A (validated against open_oura's
 * `decode_motion`), but mapping its averaged (x, y, z) vector into a durable gravitySample needs the LSB→g
 * scale the sleep stager's 0.01 g stillness threshold depends on, and that scale can only be pinned from a
 * STILL capture (issue #804). Until then, decode + store + log the vector BESIDE the incumbent, never feed
 * it to scoring on a guessed scale. This corpus is that store — a separate, clearly-labelled diagnostic file
 * for offline calibration (resting magnitude → g, cadence, coverage). It never feeds scoring, safe to delete.
 *
 * FORMAT: newline-delimited JSON (JSONL), one record per line, append-only, FIXED key order so it is stable
 * and testable byte-for-byte. Parallels [OuraActivityDumpLine].
 */
object OuraMotionDumpLine {
    /** Bump when the record shape changes so a downstream reader can branch on `schema`. v2 corrects the
     *  layout to open_oura's decode_motion (orientation = b0>>5, adds motion_seconds + low_intensity,
     *  masks intensities to 0x3f). */
    const val SCHEMA = 2

    /**
     * One JSONL record (NO trailing newline — the writer adds it). `deviceId` is a controlled registry id
     * (e.g. `oura-<serial>`) and `iso` is app-generated, so neither needs JSON string-escaping here.
     *   - ringTs:        the record's raw ring-clock timestamp (the dedup key: strictly increases per record).
     *   - utc:           the anchored wall-clock (unix seconds) for the record envelope.
     *   - iso:           human-readable UTC of `utc` (convenience for eyeballing).
     *   - orientation:   0..7 orientation code (record byte0 >> 5).
     *   - motionSeconds: seconds of motion in the window (record byte0 & 0x1f, 0..31).
     *   - x/y/z:         the ring's averaged accel vector, signed record byte × 8 (open_oura convention).
     *   - low/highIntensity: period intensity counts (record byte4/byte5 & 0x3f); null ⇒ JSON `null`.
     */
    fun encode(
        deviceId: String,
        ringTs: Long,
        utc: Long,
        iso: String,
        orientation: Int,
        motionSeconds: Int,
        x: Int,
        y: Int,
        z: Int,
        lowIntensity: Int?,
        highIntensity: Int?,
    ): String {
        val lo = lowIntensity?.toString() ?: "null"
        val hi = highIntensity?.toString() ?: "null"
        return "{\"schema\":$SCHEMA,\"deviceId\":\"$deviceId\",\"ringTs\":$ringTs," +
            "\"utc\":$utc,\"iso\":\"$iso\",\"orientation\":$orientation," +
            "\"motion_seconds\":$motionSeconds,\"x\":$x,\"y\":$y,\"z\":$z," +
            "\"low_intensity\":$lo,\"high_intensity\":$hi}"
    }
}
