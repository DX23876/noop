package com.noop.ingest

/**
 * Pure (Android-free, HC-SDK-free) planning logic for what NOOP exports INTO Health Connect.
 *
 * Everything here operates on plain Kotlin types so it is unit-testable on the JVM, mirroring
 * [HealthConnectImporter.sumActiveKcalInWindow]. [HealthConnectWriter] turns these descriptors into
 * actual Health Connect records (the untestable SDK glue is kept thin, as in `buildExerciseRecords`).
 *
 * #528 (reimplemented from @sunny-noop): close the export gaps so a strap-only user surfaces the
 * metrics NOOP genuinely computed — daily steps, active energy, heart-rate series, sleep sessions —
 * into Health Connect for other apps. Honest: only days/samples NOOP actually has are emitted; a
 * day with no steps and no active kcal produces nothing (never a fabricated zero).
 */
object HealthExportPlan {

    // ---- Heart-rate series: full-res inside workout/sleep windows, decimated elsewhere ----

    data class HrPoint(val tsSec: Long, val bpm: Int)
    data class Window(val startSec: Long, val endSec: Long)
    data class HrChunk(
        val clientId: String,
        val startSec: Long,
        val endSec: Long,
        val points: List<HrPoint>,
    )
    data class HrPlan(val chunks: List<HrChunk>, val newFrontierSec: Long)

    /**
     * Build chunked HR series from samples newer than [frontierSec]. Inside any [windows] interval
     * every sample is kept; outside, at most one sample per [decimateSec]. Each chunk spans at most
     * [chunkSec] seconds and holds at most [maxSamplesPerChunk] points. [HrPlan.newFrontierSec]
     * advances past every fresh sample seen (so decimated-away tail samples are not revisited).
     */
    fun heartRate(
        samples: List<HrPoint>,
        windows: List<Window>,
        frontierSec: Long,
        decimateSec: Long = 30,
        chunkSec: Long = 3600,
        maxSamplesPerChunk: Int = 1000,
    ): HrPlan {
        val fresh = samples.filter { it.tsSec > frontierSec }.sortedBy { it.tsSec }
        if (fresh.isEmpty()) return HrPlan(emptyList(), frontierSec)

        fun inWindow(ts: Long) = windows.any { ts >= it.startSec && ts <= it.endSec }

        val kept = ArrayList<HrPoint>()
        var lastOut = Long.MIN_VALUE / 2
        for (p in fresh) {
            if (inWindow(p.tsSec)) {
                kept.add(p); lastOut = p.tsSec
            } else if (p.tsSec - lastOut >= decimateSec) {
                kept.add(p); lastOut = p.tsSec
            }
        }

        val chunks = ArrayList<HrChunk>()
        var cur = ArrayList<HrPoint>()
        fun flush() {
            if (cur.isEmpty()) return
            chunks.add(HrChunk("noop-hr-${cur.first().tsSec}", cur.first().tsSec, cur.last().tsSec, ArrayList(cur)))
            cur = ArrayList()
        }
        for (p in kept) {
            if (cur.isNotEmpty() &&
                (p.tsSec - cur.first().tsSec >= chunkSec || cur.size >= maxSamplesPerChunk)) {
                flush()
            }
            cur.add(p)
        }
        flush()

        return HrPlan(chunks, fresh.last().tsSec)
    }

    // ---- Sleep sessions: AWAKE vs SLEEPING only (fine stages deferred until stager validated) ----

    /** One stored fragment as the export sees it: [keyStartTs] is the immutable detected onset (the
     *  dedup identity — a user edit must never change it), [startTs] the EFFECTIVE onset that drives
     *  the exported span (`startTsAdjusted ?: startTs`, iOS parity #318). */
    data class SleepInput(val keyStartTs: Long, val startTs: Long, val endTs: Long, val stagesJSON: String?)
    data class StagePlan(val startSec: Long, val endSec: Long, val asleep: Boolean)
    data class SleepPlan(
        val clientId: String,
        val startSec: Long,
        val endSec: Long,
        val stages: List<StagePlan>,
        /** The non-representative fragments' old per-fragment ids (`noop-sleep-<keyStartTs>`). Health
         *  Connect upserts by clientRecordId but never removes an id we stop writing, so a night that
         *  previously exported as two records would orphan the second when it becomes one — the
         *  writer deletes these explicitly. Empty for a single-fragment night. (#364) */
        val absorbedClientIds: List<String> = emptyList(),
    )

    /** Finalized sessions (endTs <= [nowSec]) only; never the currently-open night. Fragments are
     *  grouped into BRIDGED NIGHTS (#364) via [SleepStageTotals.bridgedNightGroups] — the SAME
     *  two-tier bridge the daily totals score with (#561/#861) — so a night the detector split on a
     *  brief mid-night wake exports as ONE session whose gap is an explicit AWAKE stage; naps never
     *  bridge and stay their own records. The clientRecordId keys off the group's EARLIEST fragment's
     *  immutable detected onset. [offsetSec] is seconds EAST of UTC (the night-tail bridge reads the
     *  local clock). */
    fun sleepSessions(sessions: List<SleepInput>, nowSec: Long, offsetSec: Long): List<SleepPlan> {
        val finalized = sessions.filter { it.endTs > it.startTs && it.endTs <= nowSec }
        if (finalized.isEmpty()) return emptyList()
        val blocks = finalized.map { com.noop.analytics.SleepStageTotals.NightBlock(it.startTs, it.endTs) }
        val out = ArrayList<SleepPlan>()
        for (group in com.noop.analytics.SleepStageTotals.bridgedNightGroups(blocks, offsetSec)) {
            val frags = group.indices.map { finalized[it] }.sortedBy { it.startTs }
            val stages = ArrayList<StagePlan>()
            var prevEnd: Long? = null
            for (f in frags) {
                val p = prevEnd
                // The inter-fragment seam is time the user was demonstrably awake — export it as an
                // explicit AWAKE stage so the merged night carries the wake instead of a silent hole.
                if (p != null && f.startTs > p) stages.add(StagePlan(p, f.startTs, asleep = false))
                stages.addAll(parseStages(f.stagesJSON))
                prevEnd = maxOf(prevEnd ?: f.endTs, f.endTs)
            }
            val rep = frags.minOf { it.keyStartTs }
            out.add(SleepPlan(
                clientId = "noop-sleep-$rep",
                startSec = frags.first().startTs,
                endSec = frags.maxOf { it.endTs },
                stages = stages,
                absorbedClientIds = frags.map { it.keyStartTs }.filter { it != rep }
                    .sorted().map { "noop-sleep-$it" },
            ))
        }
        return out
    }

    /** Parse the `{start,end,stage}` segment array; classify `wake`/`awake` as awake, else asleep;
     *  coalesce consecutive same-class segments. Returns empty on null/malformed JSON.
     *
     *  The asleep test mirrors [HealthConnectImporter] / `WhoopRepository.sleepEfficiency`, which
     *  treat any stage that is not `wake`/`awake` as asleep — so the exported AWAKE/SLEEPING split
     *  matches what the rest of NOOP already considers asleep. */
    private fun parseStages(json: String?): List<StagePlan> {
        json ?: return emptyList()
        val arr = runCatching { org.json.JSONArray(json) }.getOrNull() ?: return emptyList()
        val raw = ArrayList<StagePlan>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val st = o.optLong("start", -1L)
            val en = o.optLong("end", -1L)
            if (st < 0 || en <= st) continue
            val name = o.optString("stage")
            if (name.isEmpty()) continue // no stage label: leave a gap rather than fabricate asleep
            raw.add(StagePlan(st, en, asleep = name != "wake" && name != "awake"))
        }
        val merged = ArrayList<StagePlan>()
        for (seg in raw.sortedBy { it.startSec }) {
            val last = merged.lastOrNull()
            if (last != null && last.asleep == seg.asleep && seg.startSec <= last.endSec) {
                merged[merged.size - 1] = last.copy(endSec = maxOf(last.endSec, seg.endSec))
            } else {
                merged.add(seg)
            }
        }
        return merged
    }
}
