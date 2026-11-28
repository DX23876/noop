package com.noop.core

import org.json.JSONObject

/**
 * The note the Sleep page shows while last night is not on screen yet (`sleep.freshness`): a sync is running, the
 * night is being worked out, the sync failed, the strap has not synced since the day began, or a sync found no
 * night. Decided and worded by the shared core (`SleepFreshness`), as the iPhone's Sleep page says it. Blocking.
 */
object CoreSleepFreshness {
    data class Note(val status: String, val title: String, val message: String)

    /** The note, or null when the page needs none (a night ended today, it is still night, or no core). */
    fun note(latestWakeTs: Long?, syncing: Boolean, calculating: Boolean, lastSyncedAt: Long?, syncFailed: Boolean,
             chunks: Int): Note? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("syncing", syncing).put("calculating", calculating)
            .put("syncFailed", syncFailed).put("chunks", chunks)
        latestWakeTs?.let { args.put("latestWakeTs", it) }
        lastSyncedAt?.let { args.put("lastSyncedAt", it) }
        val json = SwiftCore.call("sleep.freshness", args.toString()) ?: return null
        return parse(json)
    }

    internal fun parse(json: String): Note? = runCatching {
        val o = JSONObject(json)
        if (o.isNull("status") || !o.has("status")) null
        else Note(o.getString("status"), o.optString("title"), o.optString("message"))
    }.getOrNull()
}
