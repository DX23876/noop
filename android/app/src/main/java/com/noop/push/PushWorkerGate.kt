package com.noop.push

/** Ordering seam: stale/disabled work exits before network, Keystore, Room, or HTTP are touched. */
internal object PushWorkerGate {
    sealed interface Outcome {
        data object DisabledOrInvalid : Outcome
        data object NetworkUnavailable : Outcome
        data object MissingToken : Outcome
        data class Executed(val retry: Boolean) : Outcome
    }

    suspend fun run(
        enabledEndpoint: () -> PushEndpointPolicy.ValidEndpoint?,
        networkAvailable: () -> Boolean,
        token: () -> String?,
        execute: suspend (PushEndpointPolicy.ValidEndpoint, String) -> Boolean,
    ): Outcome {
        val endpoint = enabledEndpoint() ?: return Outcome.DisabledOrInvalid
        if (!networkAvailable()) return Outcome.NetworkUnavailable
        val bearer = token() ?: return Outcome.MissingToken
        return Outcome.Executed(retry = execute(endpoint, bearer))
    }
}
