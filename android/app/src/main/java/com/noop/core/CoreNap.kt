package com.noop.core

import com.noop.analytics.NapCandidate
import com.noop.analytics.NapConfig
import com.noop.analytics.NapDecision
import com.noop.analytics.NapVerdict
import org.json.JSONObject

/**
 * Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`, decision 6): the nap review card's
 * verdict from the shared core (`nap.evaluate`, Swift `NapDetector`), over the strap's gravity and heart rate the
 * core stored. Null when this build has no core; the caller then keeps the Kotlin detector.
 */
object CoreNap {
    fun evaluate(deviceId: String, from: Long, to: Long, restingHr: Int?, config: NapConfig): NapDecision? {
        if (!SwiftCore.available || !CoreShadow.running) return null
        val args = JSONObject().put("deviceId", deviceId).put("from", from).put("to", to)
            .put("enabled", config.enabled).put("minNapMinutes", config.minNapMinutes)
            .put("maxNapMinutes", config.maxNapMinutes).put("stillThresholdG", config.stillThresholdG)
            .put("hrSettleMarginBpm", config.hrSettleMarginBpm).put("smoothWindowSeconds", config.smoothWindowSeconds)
        if (restingHr != null) args.put("restingHr", restingHr)
        val answer = SwiftCore.call("nap.evaluate", args.toString())?.let { runCatching { JSONObject(it) }.getOrNull() }
            ?: return null
        if (answer.has("error")) return null
        return parse(answer)
    }

    internal fun parse(answer: JSONObject): NapDecision {
        val verdict = when (answer.optString("verdict")) {
            "nap" -> NapVerdict.NAP
            "none" -> NapVerdict.NONE
            else -> NapVerdict.INCONCLUSIVE
        }
        val candidate = if (verdict == NapVerdict.NAP && answer.has("start") && answer.has("end")) {
            NapCandidate(
                start = answer.getLong("start"), end = answer.getLong("end"),
                meanHr = if (answer.isNull("meanHr") || !answer.has("meanHr")) null else answer.getInt("meanHr"),
                confidence = answer.optDouble("confidence", 0.0),
            )
        } else null
        return NapDecision(verdict, candidate)
    }
}
