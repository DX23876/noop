package com.noop.protocol

/**
 * SET_CLOCK (cmd 10) body for WHOOP 5/MG, with the sub-second part filled in.
 *
 * The 8-byte form is `[seconds u32 LE][subseconds u32 LE]`, the subseconds in 1/32768 s: the unit of the
 * EVENT header u16 at frame 16, of the GET_CLOCK reply and of the alarm body ([AlarmPayload]). Sending 0
 * floors the phone time to the whole second, so a strap set that way starts up to a second behind before
 * any radio latency. A 2026-10-31 MG capture (fw 50.41.1.0) sat 1.3 to 2.1 s behind after each set while
 * its RTC drifted less than 3 ppm. WHOOP 4 keeps `WhoopBleClient.setClockPayload`, whose zero fraction is
 * what fw 41.17.x was validated with (#120).
 *
 * Twin of the Swift `SetClockPayload`.
 */
object SetClockPayload {

    /** The 8-byte body for the instant [epochMs] (Unix milliseconds); both halves come from that instant. */
    fun withSubseconds(epochMs: Long): ByteArray {
        val ms = maxOf(0L, epochMs)
        val seconds = minOf(ms / 1000L, 0xFFFF_FFFFL)
        val subseconds = (ms % 1000L) * 32768L / 1000L
        return byteArrayOf(
            (seconds and 0xFF).toByte(),
            ((seconds shr 8) and 0xFF).toByte(),
            ((seconds shr 16) and 0xFF).toByte(),
            ((seconds shr 24) and 0xFF).toByte(),
            (subseconds and 0xFF).toByte(),
            ((subseconds shr 8) and 0xFF).toByte(),
            0,
            0,
        )
    }
}
