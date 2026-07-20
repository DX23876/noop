package com.noop.ble

import android.content.Context
import com.noop.oura.OuraActivityDumpLine
import java.io.File
import java.time.Instant

/**
 * Append-only JSONL sidecar for the Oura 0x50 activity/MET stream — the Kotlin twin of Swift
 * `OuraActivityDump`. A Tier-B RESEARCH corpus, never a datastore row (see [OuraActivityDumpLine] for the
 * honest-data rationale). Owns the file, the once-per-launch "here is the file" log line, and a persistent
 * ring-time high-water so records the ring re-serves across reconnects (observed heavily under connection
 * churn) are written exactly once instead of duplicating the corpus.
 *
 * Location: `<filesDir>/diagnostics/oura-activity-<deviceId>.jsonl` (app-private). Purely diagnostic and
 * safe to delete; nothing reads it back. (The path is platform-specific; the LINE content is byte-identical
 * to the Swift corpus — that is the parity-relevant part.)
 */
class OuraActivityDump(
    context: Context,
    private val deviceId: String,
    private val log: (String) -> Unit,
) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val highWaterKey = "highwater.$deviceId"

    /** Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
     *  Persisted so the dedup survives relaunches (a fresh drain re-emits old records). */
    private var highWater: Long = prefs.getLong(highWaterKey, 0L)
    private var file: File? = null
    private var resolveFailed = false
    private var announced = false

    /**
     * Append one anchored activity record. No-op when [ringTs] is not above the high-water (a re-serve), so
     * the corpus stays deduped. Best-effort: any file error is logged once and never disrupts the BLE path.
     * Call ONLY with an anchored [utc] (an un-anchored record has no real time axis and re-arrives anchored
     * on the next drain).
     */
    fun record(ringTs: Long, utc: Long, state: Int, secPerSample: Int, met: List<Double>) {
        if (ringTs <= highWater) return
        val f = resolveFile() ?: return

        val line = OuraActivityDumpLine.encode(
            deviceId = deviceId, ringTs = ringTs, utc = utc,
            iso = Instant.ofEpochSecond(utc).toString(),
            state = state, secPerSample = secPerSample, met = met,
        )
        try {
            f.appendText(line + "\n")
        } catch (e: Exception) {
            log("Oura: activity MET dump write failed - ${e.message}")
            return
        }

        highWater = ringTs
        prefs.edit().putLong(highWaterKey, ringTs).apply()
        if (!announced) {
            announced = true
            log("Oura: activity MET dump → ${f.absolutePath} [Tier-B research corpus, JSONL, deduped by ring-time]")
        }
    }

    /** Resolve (and create on first use) the sidecar file + its parent directory. Cached; a failure is
     *  logged once and latched so we never spam the strap log on a read-only volume. */
    private fun resolveFile(): File? {
        file?.let { return it }
        if (resolveFailed) return null
        return try {
            val dir = File(appContext.filesDir, "diagnostics").apply { mkdirs() }
            val safeId = deviceId.replace("/", "_")
            File(dir, "oura-activity-$safeId.jsonl").also {
                if (!it.exists()) it.createNewFile()
                file = it
            }
        } catch (e: Exception) {
            resolveFailed = true
            log("Oura: activity MET dump unavailable - ${e.message}")
            null
        }
    }

    private companion object {
        const val PREFS_NAME = "oura_activity_dump"
    }
}
