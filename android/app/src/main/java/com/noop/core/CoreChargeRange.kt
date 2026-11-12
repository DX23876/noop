package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876): a Charge driver's usual range from the shared core (`DriverUsualRange`, as iOS
 * `ForgeChargeDetailView.usualRange`): the middle half of the nights before, and the night placed on a 0 to 100 track
 * with that range in its middle third. Null under seven nights. Blocking; call off the main thread.
 */
object CoreChargeRange {
    data class Range(val low: Double, val high: Double, val position: Double, val bandLow: Double, val bandHigh: Double)

    fun of(value: Double, before: List<Double>): Range? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("charge.usualRange", JSONObject().put("value", value).put("before", JSONArray(before)).toString())
            ?: return null
        return runCatching {
            val o = JSONObject(json)
            Range(o.getDouble("low"), o.getDouble("high"), o.getDouble("position"), o.getDouble("bandLow"), o.getDouble("bandHigh"))
        }.getOrNull()
    }
}
