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
    data class Delta(val text: String?, val tone: String?)

    /** [key] is the shared catalog key ("hrv", "rhr", "spo2", "resp_rate", "skin_temp", "weight", ...). */
    fun delta(key: String, values: List<Double>): Delta? {
        if (!SwiftCore.available || values.size < 8) return null
        val json = SwiftCore.call("tile.delta", JSONObject().put("key", key).put("values", JSONArray(values)).toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            Delta(if (o.isNull("delta")) null else o.optString("delta"), if (o.isNull("tone")) null else o.optString("tone"))
        }.getOrNull()
    }
}
