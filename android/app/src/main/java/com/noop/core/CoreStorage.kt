package com.noop.core

import android.content.Context
import org.json.JSONObject

/**
 * Fork (DX23876), Settings parity package 5 (DB-09): the Storage page's numbers for the core's database
 * (`storage.report`, `storage.cleanUp`, the Swift `CoreStorage`). The import scratch folders in the app's cache are
 * plain files the page reads itself (`ForgeSettingsStorage`).
 */
object CoreStorage {
    /** The database with its write-ahead log in bytes, or null when the core is absent or has no file. */
    fun databaseBytes(context: Context): Long? = runCatching {
        if (!CoreShadow.openStore(context)) return@runCatching null
        parseBytes(JSONObject(SwiftCore.call("storage.report", "{}") ?: return@runCatching null))
    }.getOrNull()

    /** Folds the write-ahead log back into the database file. The database size afterwards, null when unknown. */
    fun cleanUp(context: Context): Long? = runCatching {
        if (!CoreShadow.openStore(context)) return@runCatching null
        parseBytes(JSONObject(SwiftCore.call("storage.cleanUp", "{}") ?: return@runCatching null))
    }.getOrNull()

    internal fun parseBytes(answer: JSONObject): Long? = if (answer.has("db") && !answer.isNull("db")) answer.optLong("db") else null
}
