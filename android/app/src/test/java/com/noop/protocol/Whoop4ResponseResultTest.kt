package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * WHOOP 4.0 COMMAND_RESPONSE origin-seq echo + result code (#791).
 *
 * The 5/MG path has always exposed `resp_seq` and `result`; the 4.0 path exposed neither, so a 4.0 strap log
 * could not say whether a command succeeded or failed. The reporter in #791 had to hand-decode `result=0x00`
 * out of raw hex to establish that their strap was answering `GET_EXTENDED_BATTERY_INFO` with FAILURE rather
 * than with an empty success — a materially different conclusion.
 *
 * Every frame below is a REAL capture from that report (WHOOP 4.0, Galaxy S24 Ultra), not synthesised, which
 * is what grounds the claim that payload[0] is the origin-seq echo and payload[1] the result code. The two
 * frames disagree on the result byte (0x01 vs 0x00) while agreeing on the layout, and the long-standing
 * `GET_BATTERY_LEVEL` decode has always read its value from payload[2..4] — already skipping both bytes.
 */
class Whoop4ResponseResultTest {

    private fun fromHex(s: String): ByteArray {
        val h = s.replace(" ", "")
        return ByteArray(h.length / 2) {
            ((h[it * 2].digitToInt(16) shl 4) or h[it * 2 + 1].digitToInt(16)).toByte()
        }
    }

    /** A GET_DATA_RANGE the strap actually answered: result 0x01 = SUCCESS. */
    @Test
    fun answeredDataRangeReportsSuccessAndItsOriginSeq() {
        val frame = fromHex(
            "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
                "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04",
        )
        val r = Framing.parseFrame(frame, DeviceFamily.WHOOP4)
        assertEquals("GET_DATA_RANGE(34)", r.parsed["resp_cmd"])
        assertEquals(0x0A, r.parsed["resp_seq"])
        assertEquals("SUCCESS(1)", r.parsed["result"])
    }

    /**
     * The empty extended-battery reply that is the heart of #791: acknowledged, correct origin-seq echo, and
     * result FAILURE with an all-zero payload. Before this decode a reader saw only "resp_cmd" and could not
     * tell this apart from a successful reply that happened to carry zeros.
     */
    @Test
    fun emptyExtendedBatteryReplyReportsFailureNotEmptySuccess() {
        val frame = fromHex("aa2400fa2495622200" + "00".repeat(27) + "0ac33306")
        val r = Framing.parseFrame(frame, DeviceFamily.WHOOP4)
        assertEquals("GET_EXTENDED_BATTERY_INFO(98)", r.parsed["resp_cmd"])
        assertEquals(0x22, r.parsed["resp_seq"])
        assertEquals("FAILURE(0)", r.parsed["result"])
    }

    /**
     * The duplicate-write symptom the echo makes legible. One `GET_DATA_RANGE` send produced three CRC-valid
     * responses whose strap-side sequence numbers advanced (0x7e/0x7f/0x80) while the origin-seq echo stayed
     * the same — so the strap really did receive the command three times. That repeated echo is now visible
     * in the log rather than requiring frame archaeology.
     */
    @Test
    fun duplicateResponsesShareOneOriginSeqAcrossAdvancingStrapSeq() {
        val bodyAfterCmd = "0a01010000000050070100a307010050070100000000000000020035030000" +
            "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"
        val seqs = listOf("7e", "7f", "80")
        val echoes = seqs.map { strapSeq ->
            val r = Framing.parseFrame(fromHex("aa4c00a724${strapSeq}22$bodyAfterCmd"), DeviceFamily.WHOOP4)
            assertEquals("GET_DATA_RANGE(34)", r.parsed["resp_cmd"])
            r.parsed["resp_seq"]
        }
        assertEquals(listOf(0x0A, 0x0A, 0x0A), echoes)
    }
}
