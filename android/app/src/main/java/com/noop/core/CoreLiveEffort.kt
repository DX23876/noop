package com.noop.core

import android.content.Context
import com.noop.ui.ProfileStore
import org.json.JSONObject

/**
 * Today's Effort as a Today screen must show it: the live score over today's raw heart rate, floored at
 * the stored row so the figure can never visibly drop.
 *
 * The classic dashboard has computed this for itself since #402, the Forge one read the stored row raw,
 * and the stored row only moves when the nightly pass runs. The same wearer therefore saw two different
 * Efforts depending only on which Today was open, the lower one lagging by hours (#41). The rules live in
 * the core (`LiveEffortScore`), which is also what the Apple screens read, so no surface can drift.
 *
 * Blocking; call off the main thread. Null without a core, which the caller reads as "use the stored row".
 */
object CoreLiveEffort {
    fun today(context: Context, restingHr: Int?, storedEffort: Double?): Double? {
        if (!SwiftCore.available) return null
        val profile = ProfileStore.from(context)
        val args = JSONObject()
            .put("hrMaxOverride", profile.hrMaxOverride)
            .put("age", profile.age)
        if (restingHr != null) args.put("restingHr", restingHr)
        if (storedEffort != null) args.put("storedEffort", storedEffort)
        val json = SwiftCore.call("read.liveEffort", args.toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            if (o.has("error") || o.isNull("value")) null else o.getDouble("value")
        }.getOrNull()
    }
}
