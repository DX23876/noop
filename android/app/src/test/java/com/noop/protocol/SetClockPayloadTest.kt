package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * SET_CLOCK (cmd 10) 8-byte body with real subseconds in 1/32768 s. Twin of the Swift
 * `SetClockPayloadTests`: the same instants produce the same bytes on both platforms.
 */
class SetClockPayloadTest {

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    @Test fun halfSecondEncodesAsHalfOf32768() {
        assertEquals("00a5186a00400000", hex(SetClockPayload.withSubseconds(1_780_000_000_500L)))
    }

    @Test fun lastMillisecondStaysBelowOneSecond() {
        assertEquals("00a5186adf7f0000", hex(SetClockPayload.withSubseconds(1_780_000_000_999L)))
    }

    @Test fun wholeSecondMatchesTheOldZeroSubsecondForm() {
        assertEquals("00a5186a00000000", hex(SetClockPayload.withSubseconds(1_780_000_000_000L)))
    }

    @Test fun negativeInstantClampsInsteadOfThrowing() {
        assertEquals("0000000000000000", hex(SetClockPayload.withSubseconds(-1L)))
    }
}
