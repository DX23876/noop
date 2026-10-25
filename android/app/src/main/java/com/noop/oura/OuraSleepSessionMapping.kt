package com.noop.oura

/**
 * Platform-neutral holder for the ring-PROVIDED reconstructed hypnogram night: the session bounds +
 * efficiency + the `[{start,end,stage}]` stage breakdown JSON. Kept free of the Room `SleepSession`
 * entity (it lives in `com.noop.data`) so this mapper is pure + unit-testable without the DB; the ble
 * layer converts it to the entity and upserts it under the ring's own deviceId.
 */
data class OuraSleepSession(
    val startTs: Long,
    val endTs: Long,
    val efficiency: Double?,
    val stagesJson: String,
)

/**
 * Pure twin of Swift `WhoopStore.OuraSleepSessionMapping`. Reshapes the anchored per-code hypnogram (the
 * sequence `OuraHypnogramAssembler.codesWithTimes` lays at the 30 s SleepNet epoch, after its end is
 * anchored + 0x49-refined) into a `CachedSleepSession`-shaped night.
 *
 * WHY: the raw per-code stages already persist as `OURA_SLEEP_PHASE` stream events, but nothing turns
 * them into a NIGHT with a stage breakdown the sleep surfaces read. Banking the ring-provided hypnogram
 * as a `SleepSession` under the ring's OWN deviceId (the imported/measured side, NOT the "-noop" computed
 * sibling) lets `WhoopRepository.mergeSleepRichness`'s imported-over-computed rule surface Oura's own
 * SleepNet staging over NOOP's sparse-motion computed night — "richer record wins", reusing the exact
 * arbitration that already picks a WHOOP/HC import over a computed night (#240).
 *
 * HONEST-DATA: this is PROVIDED data (Oura's on-ring classifier), only reshaped — never a new derivation.
 *
 * PARITY: the `stagesJson` string is built by hand in a FIXED key order (`start`,`end`,`stage`) so it is
 * BYTE-IDENTICAL to the Swift twin for the same codes. Keep in lockstep with `OuraSleepSessionMapping.swift`.
 */
object OuraSleepSessionMapping {

    /** Stage token per code — the on-device stager / importer convention: deep/light/rem/wake. */
    fun token(stage: OuraSleepStage): String = when (stage) {
        OuraSleepStage.DEEP -> "deep"
        OuraSleepStage.LIGHT -> "light"
        OuraSleepStage.REM -> "rem"
        OuraSleepStage.AWAKE -> "wake"
    }

    /**
     * Build the night from the anchored per-code stage sequence (ascending `ts`, one code per
     * [secondsPerCode] epoch). Adjacent equal stages merge into one `[start,end]` segment. `startTs` = first
     * code's ts; `endTs` = last code's ts + one epoch (the anchored true sleep end). `efficiency` = asleep /
     * (asleep + awake) as a 0–1 fraction (null when nothing is in bed). Returns null for an empty sequence.
     */
    fun session(codes: List<Pair<Long, OuraSleepStage>>, secondsPerCode: Long = 30L): OuraSleepSession? {
        val first = codes.firstOrNull() ?: return null
        val last = codes.last()

        // Merge adjacent equal stages into contiguous [start,end] segments.
        data class Seg(val start: Long, var end: Long, val stage: OuraSleepStage)
        val segs = ArrayList<Seg>()
        for ((ts, stage) in codes) {
            val segEnd = ts + secondsPerCode
            val lastSeg = segs.lastOrNull()
            if (lastSeg != null && lastSeg.stage == stage && lastSeg.end == ts) {
                lastSeg.end = segEnd
            } else {
                segs.add(Seg(ts, segEnd, stage))
            }
        }

        val json = segs.joinToString(separator = ",", prefix = "[", postfix = "]") {
            "{\"start\":${it.start},\"end\":${it.end},\"stage\":\"${token(it.stage)}\"}"
        }

        var asleepSec = 0L
        var awakeSec = 0L
        for ((_, stage) in codes) {
            if (stage == OuraSleepStage.AWAKE) awakeSec += secondsPerCode else asleepSec += secondsPerCode
        }
        val inBedSec = asleepSec + awakeSec
        val efficiency = if (inBedSec > 0L) asleepSec.toDouble() / inBedSec.toDouble() else null

        return OuraSleepSession(
            startTs = first.first,
            endTs = last.first + secondsPerCode,
            efficiency = efficiency,
            stagesJson = json,
        )
    }
}
