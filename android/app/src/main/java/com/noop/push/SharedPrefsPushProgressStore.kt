package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import java.security.MessageDigest

/** Encrypted durable progress plus remembered device scopes; never endpoint URLs or bearer tokens. */
class SharedPrefsPushProgressStore private constructor(
    private val prefs: SharedPreferences,
) : PushProgressStore {
    override suspend fun knownDeviceIds(): Set<String> = prefs.getStringSet(KEY_DEVICES, emptySet()).orEmpty()

    override suspend fun rememberDeviceId(deviceId: String) {
        val updated = knownDeviceIds() + deviceId
        check(prefs.edit().putStringSet(KEY_DEVICES, updated).commit()) { "Could not persist push device scope" }
    }

    override suspend fun cursor(table: PushAppendTable, deviceId: String): PushCursor? {
        val prefix = key("append", table.wireName, deviceId)
        val rowId = prefs.getLong("$prefix.row", 0L)
        val fingerprint = prefs.getString("$prefix.key", null)
        return if (rowId > 0 && fingerprint != null) PushCursor(rowId, fingerprint) else null
    }

    override suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) {
        val prefix = key("append", table.wireName, deviceId)
        check(prefs.edit().putLong("$prefix.row", cursor.rowId)
            .putString("$prefix.key", cursor.naturalKeyFingerprint).commit()) {
            "Could not persist push cursor"
        }
    }

    override suspend fun window(table: PushMutableTable, deviceId: String): PushWindowProgress? {
        val prefix = key("window", table.wireName, deviceId)
        val batch = prefs.getString("$prefix.batch", null) ?: return null
        val from = prefs.getString("$prefix.from", null) ?: return null
        val to = prefs.getString("$prefix.to", null) ?: return null
        return PushWindowProgress(
            PushWindow(
                fromDay = from,
                toDay = to,
                startTsInclusive = prefs.getLong("$prefix.start", 0L),
                endTsExclusive = prefs.getLong("$prefix.end", 0L),
            ),
            batch,
            parseDayHashes(prefs.getString("$prefix.dayHashes", null)),
        )
    }

    override suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {
        val prefix = key("window", table.wireName, deviceId)
        check(prefs.edit()
            .putString("$prefix.batch", progress.batchId)
            .putString("$prefix.from", progress.window.fromDay)
            .putString("$prefix.to", progress.window.toDay)
            .putLong("$prefix.start", progress.window.startTsInclusive)
            .putLong("$prefix.end", progress.window.endTsExclusive)
            .putString("$prefix.dayHashes", encodeDayHashes(progress.dayHashes))
            .commit()) { "Could not persist push window" }
    }

    private fun key(kind: String, table: String, deviceId: String): String =
        "$kind.$table.${sha256(deviceId)}"

    private fun encodeDayHashes(hashes: Map<String, String>): String {
        check(hashes.all { (day, hash) ->
            runCatching { java.time.LocalDate.parse(day) }.isSuccess && hash.matches(HASH_PATTERN)
        }) { "Invalid mutable day hash progress" }
        return hashes.toSortedMap().entries.joinToString(",") { (day, hash) -> "$day:$hash" }
    }

    private fun parseDayHashes(encoded: String?): Map<String, String> {
        if (encoded.isNullOrEmpty()) return emptyMap()
        return runCatching {
            encoded.split(',').associate { item ->
                val separator = item.indexOf(':')
                require(separator > 0)
                val day = item.substring(0, separator)
                val hash = item.substring(separator + 1)
                java.time.LocalDate.parse(day)
                require(hash.matches(HASH_PATTERN))
                day to hash
            }
        }.getOrDefault(emptyMap())
    }

    companion object {
        private const val PREFS = "self_hosted_push_progress"
        private const val KEY_DEVICES = "known_devices"
        private val HASH_PATTERN = Regex("[0-9a-f]{64}")

        fun from(context: Context) = SharedPrefsPushProgressStore(
            SecurePrefs.of(context.applicationContext, PREFS),
        )

        internal fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
