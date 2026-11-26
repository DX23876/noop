package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Correcting a night's times, retiring a night and taking a retirement back, all through the shared core
 * (`SleepNightEdit`, reached by `CoreSleepEdit` on the Swift side).
 *
 * Android used to do this itself, and it did it on the wrong rows. The Sleep screen draws a night the core
 * assembled from BOTH sleep lanes, the imported one and the one NOOP computes; the edit then looked the
 * night's blocks up a second time, in the imported lane alone. A wearer whose recent nights are computed
 * could therefore not correct a single one of them, and nothing said so: the empty group was dropped, the
 * write was wrapped in a catch, and no line reached the strap log (tester report 2026-11-21).
 *
 * Two rules follow from that, and this object exists to keep them:
 *
 * 1. **The caller passes the night's own blocks** ([CoreRead.Night.blocks]), so the rows written are the
 *    rows drawn. Nothing here searches by time window or picks a lane.
 * 2. **Every answer is named.** [Answer.outcome] is never absent, not even when the core is missing, so a
 *    caller cannot accidentally treat "nothing happened" as success.
 *
 * Blocking JNI calls; run them off the main thread.
 */
object CoreSleepEdit {

    /** Why an attempt ended as it did. The raw values are the core's own. */
    enum class Outcome(val raw: String) {
        SAVED("saved"),

        /**
         * Some of the night's blocks were taken out, not all: a block whose row had already gone is not a
         * failure, but the leftover fragment stays on screen, so it may not be reported as a whole
         * deletion either.
         */
        PARTIAL("partial"),

        /** The night named no rows, so there is nothing a correction could be about. */
        NO_BLOCKS("noBlocks"),

        /** Inverted, longer than a day, or wholly in the future. */
        INVALID_WINDOW("invalidWindow"),

        /** The window overlaps no part of the night. */
        NO_OVERLAP("noOverlap"),

        /** A block of the night has no stored row any more. */
        OWNER_UNRESOLVED("ownerUnresolved"),

        /** The store refused the write; nothing was changed. */
        WRITE_FAILED("writeFailed"),

        /** Nothing was there to act on (a delete or an undo that found no row). */
        NOT_FOUND("notFound"),

        /** The core is not in this build or not started. Not a refusal, an absence. */
        NO_CORE("noCore");

        companion object {
            fun of(raw: String?): Outcome = entries.firstOrNull { it.raw == raw } ?: WRITE_FAILED
        }
    }

    /** One row taken out of the night, and whether it wants a durable "the wearer deleted this" marker. */
    data class Retired(val deviceId: String, val startTs: Long, val endTs: Long, val writesTombstone: Boolean)

    /**
     * What one attempt did. [undoToken] names the retired rows the core is holding for one undo; it is
     * null when nothing was retired.
     */
    data class Answer(
        val outcome: Outcome,
        val edited: Int = 0,
        val retired: List<Retired> = emptyList(),
        val undoToken: String? = null,
        val wakeDays: List<String> = emptyList(),
        val rescore: Boolean = false,
    ) {
        /** Something was written. [Outcome.PARTIAL] counts: the rows that went are gone either way. */
        val ok: Boolean get() = outcome == Outcome.SAVED || outcome == Outcome.PARTIAL
    }

    /** Correct the bed and wake times of the night [blocks] belongs to. */
    fun editTimes(blocks: List<CoreRead.Night.Block>, newStartTs: Long, newEndTs: Long,
                  deviceId: String, method: String, motionAwareWake: Boolean,
                  allowRelocation: Boolean = false, now: Long = System.currentTimeMillis() / 1000L,
                  recipe: String = "standard"): Answer =
        call("sleep.editTimes", args(blocks).put("start", newStartTs).put("end", newEndTs)
            .put("deviceId", deviceId).put("method", method).put("motionAwareWake", motionAwareWake)
            .put("recipe", recipe)
            .put("allowRelocation", allowRelocation).put("now", now))

    /** Take the whole night out of the store, every block of it. */
    fun deleteNight(blocks: List<CoreRead.Night.Block>): Answer = call("sleep.deleteNight", args(blocks))

    /** Put back what [token] names, as the undo strip asks. */
    fun undo(token: String): Answer = call("sleep.undoRetired", JSONObject().put("token", token))

    private fun args(blocks: List<CoreRead.Night.Block>): JSONObject {
        val array = JSONArray()
        for (block in blocks) {
            array.put(JSONObject().put("startTs", block.startTs)
                          .apply { block.deviceId?.let { put("deviceId", it) } })
        }
        return JSONObject().put("blocks", array)
    }

    private fun call(op: String, args: JSONObject): Answer {
        if (!SwiftCore.available) return Answer(Outcome.NO_CORE)
        val json = SwiftCore.call(op, args.toString()) ?: return Answer(Outcome.NO_CORE)
        return runCatching { parse(json) }.getOrElse { Answer(Outcome.WRITE_FAILED) }
    }

    internal fun parse(json: String): Answer {
        val o = JSONObject(json)
        if (o.has("error")) return Answer(Outcome.NO_CORE)
        val retiredArray = o.optJSONArray("retired") ?: JSONArray()
        val retired = (0 until retiredArray.length()).map { i ->
            val r = retiredArray.getJSONObject(i)
            Retired(r.optString("deviceId"), r.getLong("startTs"), r.getLong("endTs"),
                    r.optBoolean("writesTombstone", false))
        }
        val daysArray = o.optJSONArray("wakeDays") ?: JSONArray()
        return Answer(
            outcome = Outcome.of(o.optString("outcome").ifEmpty { null }),
            edited = o.optInt("edited", 0),
            retired = retired,
            undoToken = if (o.isNull("undoToken")) null else o.optString("undoToken").ifEmpty { null },
            wakeDays = (0 until daysArray.length()).map(daysArray::getString),
            rescore = o.optBoolean("rescore", false),
        )
    }
}
