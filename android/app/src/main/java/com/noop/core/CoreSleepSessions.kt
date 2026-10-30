package com.noop.core

import com.noop.data.SleepSession
import org.json.JSONObject

/**
 * Parity plan 1.3: the sleep blocks and the learned habitual midsleep from the shared core (`read.sleepSessions`,
 * `read.habitualMidsleep`, Apple's `StoreReader.unionSleepSessions` and `habitualMidsleepSec`), over the sleep lane
 * the input lanes mirror (imported, computed and naps). Null for anything unexpected, so the repository reads Room.
 * Blocking JNI calls; run them off the main thread.
 */
object CoreSleepSessions {
    fun union(computed: Boolean, from: Long, to: Long, limit: Int, deviceId: String): List<SleepSession>? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("read.sleepSessions", JSONObject().put("computed", if (computed) 1 else 0)
            .put("from", from).put("to", to).put("limit", limit).toString()) ?: return null
        return parse(json, deviceId)
    }

    /** The learned midsleep in local seconds of the day; null during the cold start or when the core cannot answer. */
    fun habitualMidsleep(from: Long, to: Long, offsetSec: Long): Result<Long?>? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("read.habitualMidsleep", JSONObject().put("from", from).put("to", to)
            .put("offsetSec", offsetSec).toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            check(o.has("value"))
            if (o.isNull("value")) null else o.getLong("value")
        }.takeIf { it.isSuccess }
    }

    /** A block carries the device it was stored under; one without it takes [deviceId], as Room's query did. */
    internal fun parse(json: String, deviceId: String): List<SleepSession>? = runCatching {
        val a = JSONObject(json).getJSONArray("sessions")
        (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            fun long(k: String) = if (!o.has(k) || o.isNull(k)) null else o.getLong(k)
            fun double(k: String) = if (!o.has(k) || o.isNull(k)) null else o.getDouble(k)
            SleepSession(
                deviceId = if (o.has("deviceId") && !o.isNull("deviceId")) o.getString("deviceId") else deviceId,
                startTs = o.getLong("startTs"), endTs = o.getLong("endTs"),
                efficiency = double("efficiency"), restingHr = long("restingHr")?.toInt(), avgHrv = double("avgHrv"),
                stagesJSON = if (o.has("stagesJSON") && !o.isNull("stagesJSON")) o.getString("stagesJSON") else null,
                userEdited = o.optBoolean("userEdited", false), startTsAdjusted = long("startTsAdjusted"),
                stagingSparse = if (o.has("stagingSparse") && !o.isNull("stagingSparse")) o.getBoolean("stagingSparse") else null,
            )
        }
    }.getOrNull()
}
