package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import java.security.MessageDigest
import java.util.UUID

/** Stores configuration without ever placing the bearer token in ordinary preferences. */
class SelfHostedPushSettings private constructor(
    private val prefs: SharedPreferences,
    private val secrets: Lazy<SharedPreferences>,
) {
    enum class RunState { IDLE, QUEUED, RUNNING, CONTINUING, RETRYING, COMPLETE, FAILED }

    data class Snapshot(
        val enabled: Boolean,
        val wifiOnly: Boolean,
        val endpoint: PushEndpointPolicy.ValidEndpoint?,
        val hasToken: Boolean,
        val lastSuccessAt: Long?,
        val lastError: String?,
        val runState: RunState,
        val acceptedBatches: Int,
        val acceptedRecords: Long,
        val currentStream: String?,
        val supportedStreams: List<String>?,
        val capabilitiesCheckedAt: Long?,
    ) {
        val ready: Boolean get() = enabled && endpoint != null && hasToken
    }

    fun snapshot(): Snapshot {
        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        val endpoint = (PushEndpointPolicy.validate(prefs.getString(KEY_ENDPOINT, "").orEmpty()) as? PushEndpointPolicy.Result.Valid)?.endpoint
        val capabilities = capabilitiesFor(endpoint)
        return Snapshot(
            enabled = enabled,
            wifiOnly = wifiOnly(),
            endpoint = endpoint,
            hasToken = !secrets.value.getString(KEY_TOKEN, null).isNullOrBlank(),
            lastSuccessAt = prefs.getLong(KEY_LAST_SUCCESS, 0L).takeIf { it > 0 },
            lastError = prefs.getString(KEY_LAST_ERROR, null),
            runState = if (!enabled) RunState.IDLE else runCatching {
                RunState.valueOf(prefs.getString(KEY_RUN_STATE, RunState.IDLE.name).orEmpty())
            }.getOrDefault(RunState.IDLE),
            acceptedBatches = prefs.getInt(KEY_ACCEPTED_BATCHES, 0).coerceAtLeast(0),
            acceptedRecords = prefs.getLong(KEY_ACCEPTED_RECORDS, 0L).coerceAtLeast(0L),
            currentStream = prefs.getString(KEY_CURRENT_STREAM, null),
            supportedStreams = capabilities,
            capabilitiesCheckedAt = prefs.getLong(KEY_CAPABILITIES_AT, 0L)
                .takeIf { it > 0 && capabilities != null },
        )
    }

    fun endpointText(): String = prefs.getString(KEY_ENDPOINT, "").orEmpty()
    fun wifiOnly(): Boolean = prefs.getBoolean(KEY_WIFI_ONLY, true)

    fun setWifiOnly(wifiOnly: Boolean) {
        check(prefs.edit().putBoolean(KEY_WIFI_ONLY, wifiOnly).commit()) {
            "Could not persist push network policy"
        }
    }

    /** Plain-pref gate used by stale workers before opening Room or Android Keystore. */
    fun enabledEndpoint(): PushEndpointPolicy.ValidEndpoint? {
        if (!prefs.getBoolean(KEY_ENABLED, false)) return null
        return (PushEndpointPolicy.validate(endpointText()) as? PushEndpointPolicy.Result.Valid)?.endpoint
    }

    fun token(): String? = secrets.value.getString(KEY_TOKEN, null)?.takeIf { it.isNotBlank() }

    /** Stable, non-secret receiver namespace. Generated only after the worker's stale-work gates pass. */
    @Synchronized
    fun sourceId(): String {
        prefs.getString(KEY_SOURCE_ID, null)?.let { existing ->
            runCatching { UUID.fromString(existing) }.getOrNull()?.let { return it.toString() }
        }
        val generated = UUID.randomUUID().toString()
        check(prefs.edit().putString(KEY_SOURCE_ID, generated).commit()) { "Could not persist push source id" }
        return generated
    }

    /** Saving a different normalized URL changes the progress namespace; token rotation does not. */
    fun saveEndpoint(raw: String): PushEndpointPolicy.Result {
        val validation = PushEndpointPolicy.validate(raw)
        val normalized = (validation as? PushEndpointPolicy.Result.Valid)?.endpoint?.url
            ?: return validation
        val edit = prefs.edit().putString(KEY_ENDPOINT, normalized)
        if (prefs.getString(KEY_CAPABILITIES_ENDPOINT, null) != normalized) {
            edit.remove(KEY_CAPABILITIES_ENDPOINT)
                .remove(KEY_CAPABILITIES_STREAMS)
                .remove(KEY_CAPABILITIES_AT)
        }
        edit.apply()
        return validation
    }

    fun saveToken(token: String) {
        val trimmed = token.trim()
        val changed = secrets.value.getString(KEY_TOKEN, null).orEmpty() != trimmed
        secrets.value.edit().let { edit ->
            if (trimmed.isEmpty()) edit.remove(KEY_TOKEN) else edit.putString(KEY_TOKEN, trimmed)
        }.apply()
        if (changed) clearCapabilities()
    }

    fun setEnabled(enabled: Boolean): Boolean = synchronized(statusLock) {
        if (enabled && !snapshot().copy(enabled = true).ready) return@synchronized false
        val edit = prefs.edit().putBoolean(KEY_ENABLED, enabled)
        if (!enabled) edit.putString(KEY_RUN_STATE, RunState.IDLE.name)
            .remove(KEY_LAST_ERROR).remove(KEY_CURRENT_STREAM)
        check(edit.commit()) { "Could not persist push enabled state" }
        true
    }

    fun progressNamespace(
        sourceId: String,
        endpoint: PushEndpointPolicy.ValidEndpoint,
        protocolVersion: String = PushProtocol.VERSION,
        receiverStateId: String = PushCapabilities.UNSCOPED_RECEIVER_STATE_ID,
    ): String =
        MessageDigest.getInstance("SHA-256").digest(
            "$sourceId\u0000${endpoint.url}\u0000$protocolVersion\u0000$receiverStateId".toByteArray(),
        )
            .take(12).joinToString("") { "%02x".format(it) }

    fun recordSuccess(atMillis: Long = System.currentTimeMillis()) = updateWhileEnabled {
        it.putLong(KEY_LAST_SUCCESS, atMillis).remove(KEY_LAST_ERROR)
            .remove(KEY_CURRENT_STREAM)
            .putString(KEY_RUN_STATE, RunState.COMPLETE.name)
    }

    fun recordError(message: String) = updateWhileEnabled {
        it.putString(KEY_LAST_ERROR, message.take(MAX_STATUS_CHARS))
            .putString(KEY_RUN_STATE, RunState.FAILED.name)
    }

    /** Starts a new logical catch-up. Continuation workers deliberately do not reset these counters. */
    fun recordPushStarted() = updateWhileEnabled {
        it.remove(KEY_LAST_ERROR)
            .remove(KEY_CURRENT_STREAM)
            .putInt(KEY_ACCEPTED_BATCHES, 0).putLong(KEY_ACCEPTED_RECORDS, 0L)
            .putString(KEY_RUN_STATE, RunState.QUEUED.name)
    }

    fun recordRunning() = updateWhileEnabled { it.putString(KEY_RUN_STATE, RunState.RUNNING.name) }

    fun recordCurrentStream(stream: String) = updateWhileEnabled {
        require(stream in PushCapabilities.ALL.wireNames) { "unknown push stream" }
        if (prefs.getString(KEY_CURRENT_STREAM, null) == stream) return@updateWhileEnabled it
        it.putString(KEY_CURRENT_STREAM, stream)
    }

    fun recordCapabilities(
        endpoint: PushEndpointPolicy.ValidEndpoint,
        capabilities: PushCapabilities,
        atMillis: Long = System.currentTimeMillis(),
    ) = synchronized(statusLock) {
        check(prefs.edit()
            .putString(KEY_CAPABILITIES_ENDPOINT, endpoint.url)
            .putString(KEY_CAPABILITIES_STREAMS, capabilities.wireNames.joinToString(","))
            .putLong(KEY_CAPABILITIES_AT, atMillis)
            .commit()) { "Could not persist receiver capabilities" }
    }

    @Synchronized
    fun recordAcceptedBatches(batches: Int, records: Long = 0L) = synchronized(statusLock) {
        if (batches <= 0 && records <= 0) return
        if (!prefs.getBoolean(KEY_ENABLED, false)) return
        check(prefs.edit()
            .putInt(
                KEY_ACCEPTED_BATCHES,
                prefs.getInt(KEY_ACCEPTED_BATCHES, 0).coerceAtLeast(0) + batches.coerceAtLeast(0),
            )
            .putLong(
                KEY_ACCEPTED_RECORDS,
                prefs.getLong(KEY_ACCEPTED_RECORDS, 0L).coerceAtLeast(0L) + records.coerceAtLeast(0L),
            )
            .commit()) { "Could not persist push progress" }
    }

    /** Pagination and device rotation are healthy progress, never an error. */
    fun recordContinuation() = updateWhileEnabled {
        it.remove(KEY_LAST_ERROR).remove(KEY_CURRENT_STREAM)
            .putString(KEY_RUN_STATE, RunState.CONTINUING.name)
    }

    fun recordRetrying(message: String) = updateWhileEnabled {
        it.putString(KEY_LAST_ERROR, message.take(MAX_STATUS_CHARS))
            .putString(KEY_RUN_STATE, RunState.RETRYING.name)
    }

    private inline fun updateWhileEnabled(change: (SharedPreferences.Editor) -> SharedPreferences.Editor) =
        synchronized(statusLock) {
            if (!prefs.getBoolean(KEY_ENABLED, false)) return@synchronized
            check(change(prefs.edit()).commit()) { "Could not persist push status" }
        }

    private fun capabilitiesFor(endpoint: PushEndpointPolicy.ValidEndpoint?): List<String>? {
        if (endpoint == null || prefs.getString(KEY_CAPABILITIES_ENDPOINT, null) != endpoint.url) return null
        if (!prefs.contains(KEY_CAPABILITIES_STREAMS)) return null
        val encoded = prefs.getString(KEY_CAPABILITIES_STREAMS, "").orEmpty()
        if (encoded.isEmpty()) return emptyList()
        val names = encoded.split(',')
        val known = PushCapabilities.ALL.wireNames.toSet()
        return names.takeIf { it.size == it.distinct().size && it.all(known::contains) }
    }

    private fun clearCapabilities() {
        prefs.edit().remove(KEY_CAPABILITIES_ENDPOINT)
            .remove(KEY_CAPABILITIES_STREAMS).remove(KEY_CAPABILITIES_AT).apply()
    }

    fun nextDeviceIndex(namespace: String): Int = prefs.getInt("$KEY_NEXT_DEVICE.$namespace", 0).coerceAtLeast(0)

    fun saveNextDeviceIndex(namespace: String, index: Int) {
        require(index >= 0)
        prefs.edit().putInt("$KEY_NEXT_DEVICE.$namespace", index).apply()
    }

    fun cycleNeedsAnotherPass(namespace: String): Boolean =
        prefs.getBoolean("$KEY_CYCLE_MORE.$namespace", false)

    fun saveCycleNeedsAnotherPass(namespace: String, needed: Boolean) {
        prefs.edit().putBoolean("$KEY_CYCLE_MORE.$namespace", needed).apply()
    }

    fun cycleHadRejection(namespace: String): Boolean = prefs.getBoolean("$KEY_CYCLE_REJECTED.$namespace", false)

    fun saveCycleHadRejection(namespace: String, rejected: Boolean) {
        prefs.edit().putBoolean("$KEY_CYCLE_REJECTED.$namespace", rejected).apply()
    }

    /** Persists only a safe category/status, never an exception message or response body. */
    fun cycleFailure(namespace: String): PushFailure? {
        val code = prefs.getString("$KEY_CYCLE_FAILURE_CODE.$namespace", null)
            ?.let { stored -> PushFailureCode.entries.firstOrNull { it.name == stored } }
            ?: return null
        val status = prefs.getInt("$KEY_CYCLE_FAILURE_STATUS.$namespace", 0)
            .takeIf { it in 100..599 }
        val receiverCode = prefs.getString("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace", null)
            ?.takeIf { it.matches(Regex("[a-z][a-z0-9_]{0,63}")) }
        return PushFailure(code, status, receiverCode)
    }

    fun saveCycleFailure(namespace: String, failure: PushFailure?) {
        val editor = prefs.edit()
        if (failure == null) {
            editor.remove("$KEY_CYCLE_FAILURE_CODE.$namespace")
                .remove("$KEY_CYCLE_FAILURE_STATUS.$namespace")
                .remove("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace")
        } else {
            editor.putString("$KEY_CYCLE_FAILURE_CODE.$namespace", failure.code.name)
            failure.httpStatus?.let {
                editor.putInt("$KEY_CYCLE_FAILURE_STATUS.$namespace", it)
            } ?: editor.remove("$KEY_CYCLE_FAILURE_STATUS.$namespace")
            failure.receiverCode?.let {
                editor.putString("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace", it)
            } ?: editor.remove("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace")
        }
        check(editor.commit()) { "Could not persist push failure category" }
    }

    companion object {
        private const val PREFS = "self_hosted_push"
        private const val SECRETS = "self_hosted_push_secrets"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_WIFI_ONLY = "wifi_only"
        private const val KEY_ENDPOINT = "endpoint"
        private const val KEY_TOKEN = "bearer_token"
        private const val KEY_SOURCE_ID = "source_id"
        private const val KEY_LAST_SUCCESS = "last_success_at"
        private const val KEY_LAST_ERROR = "last_error"
        private const val KEY_RUN_STATE = "run_state"
        private const val KEY_ACCEPTED_BATCHES = "accepted_batches"
        private const val KEY_ACCEPTED_RECORDS = "accepted_records"
        private const val KEY_CURRENT_STREAM = "current_stream"
        private const val KEY_CAPABILITIES_ENDPOINT = "capabilities_endpoint"
        private const val KEY_CAPABILITIES_STREAMS = "capabilities_streams"
        private const val KEY_CAPABILITIES_AT = "capabilities_at"
        private const val KEY_NEXT_DEVICE = "next_device"
        private const val KEY_CYCLE_MORE = "cycle_more"
        private const val KEY_CYCLE_REJECTED = "cycle_rejected"
        private const val KEY_CYCLE_FAILURE_CODE = "cycle_failure_code"
        private const val KEY_CYCLE_FAILURE_STATUS = "cycle_failure_status"
        private const val KEY_CYCLE_FAILURE_RECEIVER_CODE = "cycle_failure_receiver_code"
        private const val MAX_STATUS_CHARS = 300
        private val statusLock = Any()

        fun from(context: Context) = SelfHostedPushSettings(
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
            lazy(LazyThreadSafetyMode.SYNCHRONIZED) { SecurePrefs.of(context.applicationContext, SECRETS) },
        )

        internal fun forTest(prefs: SharedPreferences, secrets: SharedPreferences) =
            SelfHostedPushSettings(prefs, lazyOf(secrets))
    }
}
