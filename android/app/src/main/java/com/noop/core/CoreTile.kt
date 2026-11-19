package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Forge parity 2026-11: what a Today measure tile says beside its figure, from the shared core
 * (`MeasureTileReading`, the reading the iPhone's tiles use): the latest value against the median of the 30 before it,
 * and whether that move reads good, small or large for the body. Blocking; call off the main thread. Analysis
 * migration required: no.
 */
object CoreTile {
    /** What a tile over two columns adds: the usual and the last 30 values' range, written as the tile writes them. */
    data class Summary(val usual: String, val low: String, val high: String)
    data class Delta(val text: String?, val tone: String?, val summary: Summary? = null)

    /**
     * What a tile knows about itself beyond today's figure (`MeasureFacts`): the week's average and total, the
     * newest reading with its day and how long ago that was, the change against a reading a week older, and
     * what is left of a goal. A field is null when the data cannot answer it, never a stand-in.
     *
     * One reading for both phones: the same week must not be averaged here and again in Swift, which is where
     * two numbers for one fact begin to disagree.
     */
    data class Facts(val today: Double?, val weekAverage: Double?, val weekTotal: Double?,
                     val lastValue: Double?, val lastValueText: String?,
                     val lastDay: String?, val daysSinceLast: Int?,
                     val weekChange: Double?, val quarterChange: Double?,
                     val target: Double?, val targetLeft: Double?,
                     /** The same figures as the tile writes them, formatted in the core so both phones round alike. */
                     val todayText: String?, val weekAverageText: String?, val weekTotalText: String?,
                     val weekChangeText: String?, val quarterChangeText: String?, val targetLeftText: String?,
                     /**
                      * The kit round's three (owner, 2026-11-19): the best of the last thirty days with the day it
                      * fell on, how many of the week's days reached the goal out of how many have a reading at all,
                      * how many of the last thirty days have one, and how many of the last ten readings are above
                      * the wearer's usual. [best] is null where no direction counts as better for the measure.
                      */
                     val best: Double? = null, val bestDay: String? = null, val bestText: String? = null,
                     val daysAboveTarget: Int? = null, val weekDaysWithEntry: Int = 0,
                     val daysWithEntry: Int = 0, val aboveUsualRecently: Int? = null,
                     /**
                      * What the row-wide form puts under its chart, in order, chosen in the core so both phones
                      * say the same things in the same order (`MeasureFacts.strip`). Figures arrive formatted;
                      * only the words around them are written here.
                      */
                     val strip: List<StripEntry> = emptyList())

    /**
     * One block of the strip. [item] names it ("best", "weekAverage", "weekTotal", "range", "weekChange",
     * "daysOverGoal", "daysWithEntry", "aboveUsual", "targetLeft"); the fields a block does not use are null.
     * For "weekChange" [count] is the direction: 1 up, -1 down, 0 unchanged.
     */
    data class StripEntry(val item: String, val text: String?, val text2: String?, val day: String?,
                          val count: Int?, val total: Int?)

    /**
     * Whether a measure's goal has to be RESOLVED rather than read from a key, the twin of the shared
     * `MeasureFacts.resolvesItsTarget`. Protein is the only one: its goal is the day's macro goal, out of
     * the diet plan, the fixed goal or the energy plan in a fixed order, so no key holds it and the caller
     * has to ask the core for it. The gate `test_today_tile_gallery.py` holds the two lists equal.
     */
    fun resolvesItsTarget(key: String): Boolean = key == "protein_g"

    /**
     * Which colour each measure is drawn in, by NAME ("charge", "effort", "rest", "cyan", "rose",
     * "amber", "energy"), from the shared table. The palette stays this phone's; which measure gets
     * which name is one decision and the core holds it, because the two tables had drifted apart.
     *
     * Asked once and held: it cannot change while the app runs.
     */
    val tints: Map<String, String> by lazy {
        val json = if (SwiftCore.available) SwiftCore.call("tile.tints", "{}") else null
        runCatching {
            val o = JSONObject(json ?: return@runCatching emptyMap<String, String>())
            o.keys().asSequence().associateWith { o.optString(it) }
        }.getOrDefault(emptyMap())
    }

    /**
     * [days] and [values] are one series, oldest first and the same length; [today] is the logical day key.
     * [key] is the shared CATALOGUE key ("rhr", not "restingHr"), because that is what decides the decimals.
     */
    fun facts(key: String, days: List<String>, values: List<Double>, today: String, target: Double? = null): Facts? {
        if (!SwiftCore.available || days.isEmpty() || days.size != values.size) return null
        val args = JSONObject().put("key", key).put("days", JSONArray(days)).put("values", JSONArray(values))
            .put("today", today)
        if (target != null) args.put("target", target)
        val json = SwiftCore.call("tile.facts", args.toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            fun d(name: String): Double? = if (o.isNull(name)) null else o.optDouble(name)
            fun t(name: String): String? = if (o.isNull(name)) null else o.optString(name)
            fun i(name: String): Int? = if (o.isNull(name)) null else o.optInt(name)
            Facts(d("today"), d("weekAverage"), d("weekTotal"), d("lastValue"), t("lastValueText"),
                  t("lastDay"), i("daysSinceLast"),
                  d("weekChange"), d("quarterChange"), d("target"), d("targetLeft"),
                  t("todayText"), t("weekAverageText"), t("weekTotalText"), t("weekChangeText"),
                  t("quarterChangeText"), t("targetLeftText"),
                  d("best"), t("bestDay"), t("bestText"), i("daysAboveTarget"),
                  o.optInt("weekDaysWithEntry"), o.optInt("daysWithEntry"), i("aboveUsualRecently"),
                  o.optJSONArray("strip").let { a ->
                      (0 until (a?.length() ?: 0)).map { idx ->
                          val e = a!!.getJSONObject(idx)
                          fun s(name: String): String? = if (e.isNull(name)) null else e.optString(name)
                          fun n(name: String): Int? = if (e.isNull(name)) null else e.optInt(name)
                          StripEntry(e.optString("item"), s("text"), s("text2"), s("day"), n("count"), n("total"))
                      }
                  })
        }.getOrNull()
    }

    /**
     * One Today tile's history as the iPhone's tile reads it: the days with a reading, oldest first, their
     * values, and which of skin temperature's two scales they are on (null for every other measure).
     *
     * Only the catalogue [key] travels. The source each measure is read from, and the routes that are not a
     * plain series read (the one step resolver, one skin-temperature scale), live in the core, so this phone
     * cannot read a tile's history from somewhere else than the iPhone does. Before 2026-11-19 it asked for
     * every measure under the strap's source and its weight tile got nothing back at all.
     */
    data class History(val days: List<String>, val values: List<Double>, val skinKind: String?) {
        val isEmpty: Boolean get() = days.isEmpty()
        companion object { val none = History(emptyList(), emptyList(), null) }
    }

    /**
     * The window is the core's too: how far back a tile reads is part of "where its history comes from",
     * and four measures need a year rather than the usual sixty days (`TileMeasures.windowDays`).
     */
    fun history(key: String, skinTempPrefer: String? = null): History {
        if (!SwiftCore.available) return History.none
        val args = JSONObject().put("key", key)
        if (skinTempPrefer != null) args.put("skinTempPrefer", skinTempPrefer)
        val json = SwiftCore.call("read.tileHistory", args.toString()) ?: return History.none
        return runCatching {
            val o = JSONObject(json)
            val d = o.getJSONArray("days"); val v = o.getJSONArray("values")
            // A day without its value, or the other way round, is no history at all: a tile that drew the
            // two lists against each other would date every figure wrongly.
            if (d.length() != v.length()) return@runCatching History.none
            History((0 until d.length()).map { d.getString(it) }, (0 until v.length()).map { v.getDouble(it) },
                    if (o.isNull("skinKind")) null else o.optString("skinKind"))
        }.getOrDefault(History.none)
    }

    /** [key] is the shared catalog key ("hrv", "rhr", "spo2", "resp_rate", "skin_temp", "weight", ...). */
    fun delta(key: String, values: List<Double>): Delta? {
        if (!SwiftCore.available || values.size < 8) return null
        val json = SwiftCore.call("tile.delta", JSONObject().put("key", key).put("values", JSONArray(values)).toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            val s = o.optJSONObject("summary")
            Delta(if (o.isNull("delta")) null else o.optString("delta"), if (o.isNull("tone")) null else o.optString("tone"),
                  s?.let { Summary(it.optString("usual"), it.optString("low"), it.optString("high")) })
        }.getOrNull()
    }
}
