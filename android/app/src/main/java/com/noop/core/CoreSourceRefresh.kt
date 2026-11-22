package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * The pull gesture's rules, read from the shared core (`ConnectedSourceRefresh`): who may be asked, how
 * often, and what one line says about several answers.
 *
 * No rule lives here. This is the Kotlin end of the bridge, so the iPhone and this phone cannot come to
 * different conclusions about the same pull — the fork's "logic in the core, never in Kotlin". The
 * wording is this side's, because a sentence belongs in the catalogue that is translated.
 */
object CoreSourceRefresh {

    /** What a pull can ask. One slot for the platform's health store, Health Connect here. */
    enum class Source(val raw: String) {
        HEALTH("health"), HEVY("hevy"), STRAP("strap");

        companion object {
            fun from(raw: String): Source? = entries.firstOrNull { it.raw == raw }
        }
    }

    /**
     * What one source answered. [brought] is null when the source cannot count what it fetched, which is
     * not the same as fetching nothing — reading it that way would let the line claim everything is
     * current in the same breath as three workouts arriving.
     */
    data class Answer(val source: Source, val brought: Int? = 0, val failed: Boolean = false)

    /** What the screen should say. The platform words it; see `forge_refresh_*`. */
    sealed interface Verdict {
        /** Nothing ran, or only the strap did: say nothing at all. */
        data object None : Verdict
        data object UpToDate : Verdict

        /** Something ran and brought no count of its own: said rather than promising "up to date". */
        data object Refreshed : Verdict

        /** Only the strap was asked: no claim about freshness, but not silence either. */
        data object StrapAsked : Verdict
        data class Brought(val total: Int) : Verdict
        data class Partial(val failed: List<Source>, val brought: Int) : Verdict
    }

    private fun call(op: String, args: JSONObject): JSONObject =
        if (SwiftCore.available) runCatching { JSONObject(SwiftCore.call(op, args.toString())) }
            .getOrDefault(JSONObject())
        else JSONObject()

    /**
     * The connected sources that may be asked right now. [lastAsked] is unix seconds per source; a source
     * that has never been asked may always be asked.
     */
    fun askable(connected: Set<Source>, lastAsked: Map<Source, Long>, nowTs: Long): Set<Source> {
        val args = JSONObject()
            .put("connected", JSONArray(connected.map { it.raw }))
            .put("lastAsked", JSONObject().apply { lastAsked.forEach { (s, ts) -> put(s.raw, ts) } })
            .put("now", nowTs)
        val raw = call("refresh.askable", args).optJSONArray("askable") ?: return emptySet()
        return buildSet {
            for (i in 0 until raw.length()) Source.from(raw.optString(i))?.let { add(it) }
        }
    }

    /** One verdict from the answers; the strap never decides it (it runs for minutes and shows its own). */
    fun verdict(answers: List<Answer>): Verdict {
        val rows = JSONArray()
        for (a in answers) {
            val row = JSONObject().put("source", a.source.raw).put("failed", a.failed)
            if (a.brought != null) row.put("brought", a.brought)
            rows.put(row)
        }
        val reply = call("refresh.verdict", JSONObject().put("answers", rows))
        return when (reply.optString("verdict")) {
            "upToDate" -> Verdict.UpToDate
            "refreshed" -> Verdict.Refreshed
            "strapAsked" -> Verdict.StrapAsked
            "brought" -> Verdict.Brought(reply.optInt("total"))
            "partial" -> {
                val failed = reply.optJSONArray("failed") ?: JSONArray()
                Verdict.Partial(
                    failed = (0 until failed.length()).mapNotNull { Source.from(failed.optString(it)) },
                    brought = reply.optInt("brought"),
                )
            }
            else -> Verdict.None
        }
    }
}
