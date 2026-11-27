package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
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
    /**
     * The resting heart rate Effort is scored against on [day] (`yyyy-MM-dd`), as the core resolves it for the
     * day (`EffortRestingHR`): what the daily pass stored, else the nights before. Null without a core.
     * Blocking; call off the main thread.
     */
    fun effortRestingHR(day: String): Double? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("read.effortRestingHR", JSONObject().put("day", day).toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            if (o.has("error") || o.isNull("value")) null else o.getDouble("value")
        }.getOrNull()
    }

    /** The resting heart rate is Effort's own for the day, read by the core (`StoreReader.effortRestingHR`). */
    fun today(context: Context, storedEffort: Double?): Double? {
        if (!SwiftCore.available) return null
        val profile = ProfileStore.from(context)
        val args = JSONObject()
            .put("hrMaxOverride", profile.hrMaxOverride)
            .put("age", profile.age)
            // Which day the figure is for: in sleep-onset mode the day starts when the wearer fell
            // asleep, and the core takes the span from there (`CycleDayWindow`).
            .put("dayCycleMode", NoopPrefs.dayCycleMode(context).persistedValue)
        if (storedEffort != null) args.put("storedEffort", storedEffort)
        val json = SwiftCore.call("read.liveEffort", args.toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            if (o.has("error") || o.isNull("value")) null else o.getDouble("value")
        }.getOrNull()
    }
}
