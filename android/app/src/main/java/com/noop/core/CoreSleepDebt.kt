package com.noop.core

import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the sleep-debt ledger from the shared core (`CoreSleepDebt`), worded as
 * the iPhone's card words it. Blocking; call off the main thread.
 */
object CoreSleepDebt {
    data class Ledger(
        val nightCount: Int, val onTarget: Boolean, val isDebt: Boolean, val deltas: List<Double>, val headline: String,
        val tag: String, val read: String, val balanceText: String, val needText: String, val tone: String,
    )

    fun read(): Ledger? {
        if (!SwiftCore.available) return null
        return SwiftCore.call("sleep.debt", "{}")?.let(::parse)
    }

    internal fun parse(json: String): Ledger? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        if (!o.has("nightCount")) return null
        val d = o.optJSONArray("deltas")
        return Ledger(o.getInt("nightCount"), o.optBoolean("onTarget"), o.optBoolean("isDebt"),
                      (0 until (d?.length() ?: 0)).map { d!!.getDouble(it) }, o.optString("headline"), o.optString("tag"),
                      o.optString("read"), o.optString("balanceText"), o.optString("needText"), o.optString("tone"))
    }
}
