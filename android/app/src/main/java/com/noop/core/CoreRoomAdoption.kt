package com.noop.core

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`): an install that still has the Room
 * store of an earlier build hands it to the core once, on the first start of this one (`store.adoptRoom`, the
 * Swift `RoomStoreAdoption`). The file is then renamed and kept, so a failed adoption loses nothing; Settings can
 * delete it, and it goes by itself 30 days after an adoption that succeeded.
 */
object CoreRoomAdoption {
    private const val TAG = "CoreRoomAdoption"
    private const val PREFS = "forge"
    private const val KEY_ADOPTED_AT = "coreRoomAdoptedAt"

    /** The Room store's file name in every earlier build (`WhoopDatabase.DB_NAME`). */
    internal const val ROOM_DB_NAME = "noop_whoop.db"
    internal const val LEGACY_DB_NAME = "noop_whoop-legacy.db"
    internal const val KEEP_MS = 30L * 24 * 60 * 60 * 1000

    private val SIDECARS = listOf("", "-wal", "-shm", "-journal")

    sealed interface Outcome {
        /** Nothing to adopt: a fresh install, or the adoption happened before. */
        data object NotNeeded : Outcome
        data class Adopted(val copiedRows: Int) : Outcome
        /** The Room file stays where it was and the next start tries again. */
        data class Failed(val why: String) : Outcome
    }

    /**
     * Adopts the Room store if there is one and it was not adopted yet; removes the kept copy once its time is up.
     * Blocks; call off the main thread, after the core's store is open and before anything reads it for a screen.
     */
    fun adoptIfNeeded(context: Context, nowMs: Long = System.currentTimeMillis()): Outcome {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val room = context.getDatabasePath(ROOM_DB_NAME)
        val adoptedAt = prefs.getLong(KEY_ADOPTED_AT, 0L)
        if (adoptedAt > 0 && shouldDeleteLegacy(adoptedAt, nowMs)) deleteLegacy(context)
        if (!room.isFile) return Outcome.NotNeeded
        if (!SwiftCore.available) return Outcome.Failed("noCore")
        val answer = SwiftCore.call("store.adoptRoom", JSONObject().put("path", room.path).toString())
            ?.let { runCatching { JSONObject(it) }.getOrNull() }
            ?: return Outcome.Failed("noAnswer").also { Log.e(TAG, "the core gave no answer") }
        if (!answer.optBoolean("ok")) {
            val why = answer.optString("error", "unknown")
            Log.e(TAG, "adoption failed: $why ${answer.optString("detail")}")
            return Outcome.Failed(why)
        }
        val copied = answer.optJSONObject("copied")
        val total = copied?.keys()?.asSequence()?.sumOf { copied.optInt(it) } ?: 0
        Log.i(TAG, "adopted Room v${answer.opt("roomVersion")}: $total rows, copied=$copied skipped=${answer.optJSONObject("skipped")}")
        for (suffix in SIDECARS) {
            val from = File(room.path + suffix)
            if (from.exists() && !from.renameTo(File(room.parentFile, LEGACY_DB_NAME + suffix))) {
                Log.w(TAG, "could not rename ${from.name}")
            }
        }
        prefs.edit().putLong(KEY_ADOPTED_AT, nowMs).apply()
        CoreShadow.noteDataChanged()
        return Outcome.Adopted(total)
    }

    internal fun shouldDeleteLegacy(adoptedAtMs: Long, nowMs: Long): Boolean = nowMs - adoptedAtMs >= KEEP_MS

    /** The kept Room file's size, 0 when there is none. */
    fun legacyBytes(context: Context): Long {
        val dir = context.getDatabasePath(LEGACY_DB_NAME).parentFile ?: return 0
        return SIDECARS.sumOf { File(dir, LEGACY_DB_NAME + it).takeIf(File::isFile)?.length() ?: 0L }
    }

    /** Deletes the kept Room file and its sidecars. */
    fun deleteLegacy(context: Context): Boolean {
        val dir = context.getDatabasePath(LEGACY_DB_NAME).parentFile ?: return false
        return SIDECARS.map { File(dir, LEGACY_DB_NAME + it) }.filter(File::exists).all(File::delete)
    }
}
