package com.noop.push

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PushTransportFailureTest {
    @Test fun networkExceptionsMapToActionableSanitizedCategories() {
        val cases = listOf(
            UnknownHostException("secret.example") to PushFailureCode.DNS_LOOKUP,
            SSLPeerUnverifiedException("certificate for secret.example") to PushFailureCode.TLS_CERTIFICATE,
            SSLHandshakeException("handshake with secret.example") to PushFailureCode.TLS_HANDSHAKE,
            SocketTimeoutException("timeout at secret.example") to PushFailureCode.NETWORK_TIMEOUT,
            ConnectException("Connection refused: secret.example") to PushFailureCode.CONNECTION_REFUSED,
            NoRouteToHostException("secret.example") to PushFailureCode.NETWORK_UNREACHABLE,
            SocketException("Connection reset by secret.example") to PushFailureCode.CONNECTION_RESET,
            IOException("Bearer canary-secret") to PushFailureCode.NETWORK_IO,
        )

        for ((throwable, expected) in cases) {
            val failure = classifyPushTransportFailure(throwable)
            assertEquals(expected, failure.code)
            assertFalse(failure.safeCode.contains("secret", ignoreCase = true))
            assertFalse(failure.safeCode.contains("example", ignoreCase = true))
        }
    }

    @Test fun httpStatusesMapWithoutIncludingBodiesOrEndpoints() {
        val cases = mapOf(
            401 to PushFailureCode.HTTP_AUTH,
            404 to PushFailureCode.HTTP_NOT_FOUND,
            408 to PushFailureCode.HTTP_TIMEOUT,
            413 to PushFailureCode.HTTP_TOO_LARGE,
            415 to PushFailureCode.HTTP_MEDIA_TYPE,
            422 to PushFailureCode.HTTP_PROTOCOL_REJECTED,
            429 to PushFailureCode.HTTP_RATE_LIMIT,
            503 to PushFailureCode.HTTP_SERVER,
        )
        for ((status, expected) in cases) {
            val failure = PushFailure.http(status)
            assertEquals(expected, failure.code)
            assertEquals(status, failure.httpStatus)
        }
    }
}
