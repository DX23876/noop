package com.noop.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class PushWorkerGateTest {
    @Test fun staleDisabledWorkReturnsWithoutNetworkTokenDatabaseOrHttp() = runBlocking {
        var networkCalls = 0
        var tokenCalls = 0
        var executeCalls = 0

        val outcome = PushWorkerGate.run(
            enabledEndpoint = { null },
            networkAvailable = { networkCalls++; true },
            token = { tokenCalls++; "secret" },
            execute = { _, _ -> executeCalls++; false },
        )

        assertEquals(PushWorkerGate.Outcome.DisabledOrInvalid, outcome)
        assertEquals(0, networkCalls)
        assertEquals(0, tokenCalls)
        assertEquals(0, executeCalls)
    }

    @Test fun disallowedNetworkStopsBeforeKeystoreDatabaseAndHttp() = runBlocking {
        val endpoint = (PushEndpointPolicy.validate("https://example.com/") as PushEndpointPolicy.Result.Valid).endpoint
        var tokenCalls = 0
        var executeCalls = 0

        val outcome = PushWorkerGate.run(
            enabledEndpoint = { endpoint },
            networkAvailable = { false },
            token = { tokenCalls++; "secret" },
            execute = { _, _ -> executeCalls++; false },
        )

        assertEquals(PushWorkerGate.Outcome.NetworkUnavailable, outcome)
        assertEquals(0, tokenCalls)
        assertEquals(0, executeCalls)
    }
}
