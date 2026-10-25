package com.noop.push

import android.content.Context
import android.content.SharedPreferences

/** Durable owner/pending handshake spanning reservation, RUNNING, and WorkManager BACKOFF. */
internal object PushRunSignal {
    data class Settlement(val owned: Boolean, val pending: Boolean)
    private const val PREFS = "self_hosted_push_signal"
    private const val KEY_OWNER = "owner"
    private const val KEY_STATE = "state"
    private const val KEY_RESERVED_AT = "reserved_at"
    private const val KEY_PENDING = "pending"
    private const val STATE_RESERVED = "reserved"
    private const val STATE_RUNNING = "running"
    private const val STATE_BACKOFF = "backoff"
    private const val RESERVATION_TTL_MILLIS = 2 * 60 * 1_000L
    private val lock = Any()

    /** Atomically reserves an empty slot, expires an abandoned reservation, or coalesces a trigger. */
    fun reserve(context: Context, requestId: String): Boolean =
        reserve(prefs(context), requestId, System.currentTimeMillis())

    internal fun reserve(prefs: SharedPreferences, requestId: String, now: Long = 0L): Boolean = synchronized(lock) {
        val owner = prefs.getString(KEY_OWNER, null)
        val staleReservation = owner != null && prefs.getString(KEY_STATE, null) == STATE_RESERVED &&
            now - prefs.getLong(KEY_RESERVED_AT, now) >= RESERVATION_TTL_MILLIS
        if (owner != null && !staleReservation) {
            check(prefs.edit().putBoolean(KEY_PENDING, true).commit()) { "Could not persist push trigger" }
            false
        } else {
            check(prefs.edit().putString(KEY_OWNER, requestId).putString(KEY_STATE, STATE_RESERVED)
                .putLong(KEY_RESERVED_AT, now).putBoolean(KEY_PENDING, false).commit()) {
                "Could not reserve push work"
            }
            true
        }
    }

    fun begin(context: Context, requestId: String) = begin(prefs(context), requestId)

    internal fun begin(prefs: SharedPreferences, requestId: String) = synchronized(lock) {
        val owner = prefs.getString(KEY_OWNER, null)
        check(owner == null || owner == requestId) { "Push work owner mismatch" }
        check(prefs.edit().putString(KEY_OWNER, requestId).putString(KEY_STATE, STATE_RUNNING)
            .remove(KEY_RESERVED_AT).commit()) { "Could not persist push worker owner" }
    }

    /** Retry retains ownership through BACKOFF; terminal completion compare-and-clears this owner. */
    fun finish(context: Context, requestId: String, willRetry: Boolean): Boolean =
        finish(prefs(context), requestId, willRetry)

    internal fun finish(prefs: SharedPreferences, requestId: String, willRetry: Boolean): Boolean =
        settle(prefs, requestId, willRetry) {}.pending

    /**
     * Reads pending, commits the caller's status, then releases/transitions the owner under one lock.
     * A trigger can therefore land either before the status decision (and force CONTINUING) or after
     * release (and write QUEUED itself), but an old worker can never overwrite the newer trigger.
     */
    fun settle(
        context: Context,
        requestId: String,
        willRetry: Boolean,
        updateStatus: (pending: Boolean) -> Unit,
    ): Settlement = settle(prefs(context), requestId, willRetry, updateStatus)

    internal fun settle(
        prefs: SharedPreferences,
        requestId: String,
        willRetry: Boolean,
        updateStatus: (pending: Boolean) -> Unit,
    ): Settlement = synchronized(lock) {
        if (prefs.getString(KEY_OWNER, null) != requestId) return@synchronized Settlement(false, false)
        val pending = prefs.getBoolean(KEY_PENDING, false)
        updateStatus(pending)
        // Only a genuine failure retry keeps this request as owner through WorkManager backoff.
        // Healthy continuation returns success and is queued as a fresh request by the caller.
        val keepOwner = willRetry
        val edit = prefs.edit().putBoolean(KEY_PENDING, false).remove(KEY_RESERVED_AT)
        if (keepOwner) edit.putString(KEY_STATE, STATE_BACKOFF) else edit.remove(KEY_OWNER).remove(KEY_STATE)
        check(edit.commit()) { "Could not finish push worker owner" }
        Settlement(true, pending)
    }

    /** Safe before begin: a failed enqueue cannot clear a running or backoff owner. */
    fun releaseReservation(context: Context, requestId: String): Boolean =
        releaseReservation(prefs(context), requestId) {}

    internal fun releaseReservation(prefs: SharedPreferences, requestId: String): Boolean =
        releaseReservation(prefs, requestId) {}

    fun releaseReservation(
        context: Context,
        requestId: String,
        updateStatus: (pending: Boolean) -> Unit,
    ): Boolean = releaseReservation(prefs(context), requestId, updateStatus)

    internal fun releaseReservation(
        prefs: SharedPreferences,
        requestId: String,
        updateStatus: (pending: Boolean) -> Unit,
    ): Boolean = synchronized(lock) {
        if (prefs.getString(KEY_OWNER, null) == requestId && prefs.getString(KEY_STATE, null) == STATE_RESERVED) {
            val pending = prefs.getBoolean(KEY_PENDING, false)
            // Status is committed while this owner still excludes a successor. A new QUEUED owner
            // can therefore only write after this failed owner's status decision is finished.
            updateStatus(pending)
            check(prefs.edit().remove(KEY_OWNER).remove(KEY_STATE).remove(KEY_RESERVED_AT).remove(KEY_PENDING).commit()) {
                "Could not release push reservation"
            }
            pending
        } else {
            false
        }
    }

    fun clear(context: Context) = clear(prefs(context))
    internal fun clear(prefs: SharedPreferences) = synchronized(lock) { prefs.edit().clear().apply() }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
