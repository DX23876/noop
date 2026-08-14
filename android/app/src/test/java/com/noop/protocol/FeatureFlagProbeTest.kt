package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #761: byte-parity twin of the Swift `FeatureFlagProbeTests` — same synthetic fixtures, same
 * expectations — for the read-only feature-flag enumeration probe. Fixtures are SYNTHETIC (built here
 * with real CRCs) because the layout is reverse-engineered and not yet answered by a strap in this
 * project's hands; they pin the decode/report contract, including every failure path.
 */
class FeatureFlagProbeTest {

    /** WHOOP 4.0 COMMAND_RESPONSE: [0xAA][len u16 LE][crc8(len)][type=36][seq][cmd][payload…][crc32 LE]. */
    private fun whoop4Response(cmd: Int, payload: ByteArray, seq: Int = 1): ByteArray {
        val inner = byteArrayOf(36, seq.toByte(), cmd.toByte()) + payload
        val length = inner.size + 4
        val lenBytes = byteArrayOf((length and 0xFF).toByte(), ((length shr 8) and 0xFF).toByte())
        val c = Crc.crc32(inner)
        return byteArrayOf(0xAA.toByte()) + lenBytes + byteArrayOf(Crc.crc8(lenBytes).toByte()) + inner +
            byteArrayOf(
                (c and 0xFFL).toByte(), ((c shr 8) and 0xFFL).toByte(),
                ((c shr 16) and 0xFFL).toByte(), ((c shr 24) and 0xFFL).toByte(),
            )
    }

    /** WHOOP 5/MG COMMAND_RESPONSE in the puffin envelope: type @8, seq @9, cmd @10, record from @11. */
    private fun whoop5Response(cmd: Int, payload: ByteArray, seq: Int = 1): ByteArray {
        var inner = byteArrayOf(36, seq.toByte(), cmd.toByte()) + payload
        val pad = (4 - inner.size % 4) % 4
        if (pad > 0) inner += ByteArray(pad)
        val declLen = inner.size + 4
        val head = byteArrayOf(
            0xAA.toByte(), 0x01, (declLen and 0xFF).toByte(), ((declLen shr 8) and 0xFF).toByte(),
            0x00, 0x01,
        )
        val c16 = Crc.crc16Modbus(head)
        val c32 = Crc.crc32(inner)
        return head + byteArrayOf((c16 and 0xFF).toByte(), ((c16 shr 8) and 0xFF).toByte()) + inner +
            byteArrayOf(
                (c32 and 0xFFL).toByte(), ((c32 shr 8) and 0xFFL).toByte(),
                ((c32 shr 16) and 0xFFL).toByte(), ((c32 shr 24) and 0xFFL).toByte(),
            )
    }

    /** The 2-byte response header every COMMAND_RESPONSE carries, then the record. */
    private fun payload(result: Int, record: ByteArray): ByteArray =
        byteArrayOf(0x0A, result.toByte()) + record

    private fun keyBytes(s: String, pad: Int = 8): ByteArray =
        s.toByteArray(Charsets.US_ASCII) + byteArrayOf(0) + ByteArray(pad)

    @Test fun opcodesAreTheEnumeratePairOnly() {
        assertEquals(117, FeatureFlagProbe.START_KEY_EXCHANGE_CMD)
        assertEquals(118, FeatureFlagProbe.SEND_NEXT_FLAG_CMD)
        assertEquals(1, FeatureFlagProbe.REQUEST_BODY.size)
        assertEquals(1, FeatureFlagProbe.REQUEST_BODY[0].toInt())
    }

    @Test fun startDecodesRevisionAndCountOnWhoop4() {
        val frame = whoop4Response(117, payload(1, byteArrayOf(0x01, 0x0B, 0x00)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(1, r.revision)
        assertEquals(11, r.count)
        assertNull(r.resultCode)
        assertTrue(r.countIsPlausible)
    }

    @Test fun startDecodesOnWhoop5AndSurfacesTheResultCode() {
        val frame = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x10, 0x00)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(16, r.count)
        assertEquals(1, r.resultCode)
    }

    @Test fun startWithUnsupportedResultIsStillDecodedAndVerdictSaysRejected() {
        val frame = whoop5Response(117, payload(3, byteArrayOf(0x00, 0x00, 0x00)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(3, r.resultCode)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(r)
        assertTrue(report.verdict.contains("REJECTED by firmware (UNSUPPORTED)"))
        assertTrue(report.render().contains("opcode 117 REJECTED"))
    }

    @Test fun implausibleCountIsFlaggedNotTrusted() {
        val frame = whoop4Response(117, payload(1, byteArrayOf(0x01, 0xFF.toByte(), 0xFF.toByte())))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(65535, r.count)
        assertFalse(r.countIsPlausible)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(r)
        assertTrue(report.render().contains("count outside 1…128"))
    }

    @Test fun nextDecodesTheKeyName() {
        val record = byteArrayOf(0x01, 0x00, 0x01) + keyBytes("enable_r22_packets")
        val frame = whoop4Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(0, r.index)
        assertTrue(r.validKey)
        assertEquals("enable_r22_packets", r.key)
        assertFalse(r.isExhausted)
    }

    @Test fun nextDecodesOnWhoop5Too() {
        val record = byteArrayOf(0x01, 0x03, 0x01) + keyBytes("sigproc_wear_detect")
        val frame = whoop5Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(3, r.index)
        assertEquals("sigproc_wear_detect", r.key)
        assertEquals(1, r.resultCode)
    }

    @Test fun exhaustedCursorIsTheEndMarker() {
        val frame = whoop4Response(118, payload(1, byteArrayOf(0x01, 0xFF.toByte(), 0x00, 0x00)))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertEquals(0xFF, r.index)
        assertTrue(r.isExhausted)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        assertFalse(report.noteNext(r))
        assertEquals("cursor exhausted (index 0xFF)", report.stopReason)
    }

    /**
     * `validKey = 0` alone is NOT classified as the strap's end marker any more — it is an empty slot,
     * and the walk steps over it. The entry itself is still never collected as a key.
     */
    @Test fun validKeyFalseIsAnEmptySlotNotTheEndMarker() {
        val record = byteArrayOf(0x01, 0x04, 0x00) + keyBytes("stale_buffer_leftover")
        val frame = whoop4Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertFalse(r.validKey)
        assertFalse("only index=0xFF is the strap's unambiguous end marker", r.isExhausted)
        assertTrue(r.isEmptySlot)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        assertTrue("validKey=0 without 0xFF must not end the walk", report.noteNext(r))
        assertNull(report.stopReason)
        assertEquals(1, report.emptySlots)
        assertTrue(report.keys.isEmpty())
    }

    /**
     * The whole experiment, in one walk: the strap serves `validKey = 0` mid-list, the walk keeps asking,
     * and the strap names MORE keys before ending on 0xFF. That sequence is decisive — under the old rule
     * this list would have been reported as one key long.
     */
    @Test fun walkContinuesPastValidKeyZeroAndCollectsTheKeysAfterIt() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 5, listOf<Byte>(0x01, 0x05, 0x00)))
        fun next(index: Int, valid: Boolean, key: String?) = FeatureFlagProbe.NextResponse(
            1, 1, index, valid, key,
            listOf<Byte>(0x01, index.toByte(), if (valid) 0x01 else 0x00),
        )
        assertTrue(report.noteNext(next(1, true, "enable_r22_packets")))
        assertTrue("an empty slot must not end the walk", report.noteNext(next(2, false, null)))
        assertTrue("nor must a second one", report.noteNext(next(3, false, null)))
        assertTrue(report.noteNext(next(4, true, "enable_sig12")))
        assertFalse(report.noteNext(next(0xFF, false, null)))

        assertEquals(listOf("enable_r22_packets", "enable_sig12"), report.keys)
        assertEquals(2, report.emptySlots)
        assertEquals(1, report.keysAfterFirstEmptySlot)
        assertEquals(FeatureFlagProbe.StopCode.END_MARKER, report.stopCode)
        val finding = report.terminatorFinding
        assertTrue(finding, finding.startsWith("DECISIVE — validKey=0 is an EMPTY/RETIRED SLOT"))
        assertTrue(finding, finding.contains("naming 1 more key(s)"))
        assertTrue(report.render().contains("2 validKey=0 slot(s) stepped over"))
    }

    /**
     * #874's rule reaches the CONCLUSION too. The strap flagged an entry past the hole as real; our ASCII
     * filter declined its name. The list still continued, so the finding must still be decisive — reading
     * "inconclusive" here would be our parser deciding a question about the firmware.
     */
    @Test fun anUndecodableEntryAfterAnEmptySlotIsStillDecisive() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 30, listOf<Byte>(0x01, 0x1E, 0x00)))
        assertTrue(
            report.noteNext(
                FeatureFlagProbe.NextResponse(1, 1, 1, false, null, listOf<Byte>(0x01, 0x01, 0x00)),
            ),
        )
        assertTrue(
            report.noteNext(
                FeatureFlagProbe.NextResponse(
                    1, 1, 2, true, null, listOf<Byte>(0x01, 0x02, 0x01, 0xDE.toByte(), 0xAD.toByte()),
                ),
            ),
        )
        assertEquals("no name decoded, so no key is invented", emptyList<String>(), report.keys)
        assertEquals(0, report.keysAfterFirstEmptySlot)
        assertEquals(1, report.validEntriesAfterFirstEmptySlot)
        val finding = report.terminatorFinding
        assertTrue(finding, finding.startsWith("DECISIVE — validKey=0 is an EMPTY/RETIRED SLOT"))
        assertTrue(finding, finding.contains("1 of them flagged validKey=1"))
        assertFalse(finding, finding.contains("naming"))
    }

    /**
     * The other decisive outcome, and the one that costs two round-trips: the strap repeats the same index
     * with `validKey = 0`. What that decides is that the cursor does not advance, so this walk cannot see
     * past the point — NOT that the list ends there. A firmware whose cursor parks on an empty slot emits
     * the identical frame, and that is the reading this whole probe exists to make testable, so the
     * verdict must not print it as settled. Both halves are pinned below.
     */
    @Test fun repeatedEmptySlotAtTheSameIndexIsReportedAsATerminator() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 9, listOf<Byte>(0x01, 0x09, 0x00)))
        val empty = FeatureFlagProbe.NextResponse(1, 1, 7, false, null, listOf<Byte>(0x01, 0x07, 0x00))
        assertTrue("the first empty slot is stepped over", report.noteNext(empty))
        assertFalse("a parked cursor ends the walk", report.noteNext(empty))
        assertEquals(FeatureFlagProbe.StopCode.EMPTY_SLOT_CURSOR_PARKED, report.stopCode)
        assertTrue(
            report.terminatorFinding,
            report.terminatorFinding.startsWith("DECISIVE — validKey=0 is a TERMINATOR"),
        )
        // The narrowing, pinned so it cannot be quietly widened back. "There is nothing past it" is the
        // conclusion a reader would paste into an issue as settled, and it is the one this probe exists
        // to question — two firmwares emit this identical frame.
        assertTrue(
            report.terminatorFinding,
            report.terminatorFinding.contains("the cursor does not advance past it"),
        )
        assertTrue(
            report.terminatorFinding,
            report.terminatorFinding.contains(
                "not separable from a firmware whose cursor parks on an empty slot",
            ),
        )
        assertFalse(
            "the walk observes a stalled cursor, not an empty tail: ${report.terminatorFinding}",
            report.terminatorFinding.contains("there is nothing past it"),
        )
        assertEquals("settling this must cost two round-trips, not a full cap", 2, report.steps)
    }

    /**
     * A firmware that answers `validKey = 0` forever with an ADVANCING index cannot run the walk away: the
     * consecutive-empty cap stops it, and names itself a CLIENT-side bound so the run is never read as a
     * complete list.
     */
    @Test fun anUnendingRunOfEmptySlotsStopsAtTheConsecutiveCap() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        var index = 0
        var sent = 0
        while (report.noteNext(
                FeatureFlagProbe.NextResponse(1, 1, index, false, null, listOf<Byte>(0x01, index.toByte(), 0x00)),
            )
        ) {
            index += 1
            sent += 1
            assertTrue("walk must not run away", sent < FeatureFlagProbe.MAX_CONSECUTIVE_EMPTY_SLOTS + 2)
        }
        assertEquals(FeatureFlagProbe.MAX_CONSECUTIVE_EMPTY_SLOTS, report.steps)
        assertEquals(FeatureFlagProbe.StopCode.EMPTY_SLOT_RUN_CAP, report.stopCode)
        val why = report.stopReason!!
        assertTrue(why, why.contains("a CLIENT-side bound, not the strap's"))
        assertTrue(report.terminatorFinding, report.terminatorFinding.startsWith("INCONCLUSIVE"))
    }

    /** A valid entry resets the run, so scattered holes cost nothing against the cap. */
    @Test fun aValidEntryResetsTheConsecutiveEmptySlotRun() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        fun empty(i: Int) = FeatureFlagProbe.NextResponse(1, 1, i, false, null, listOf<Byte>(0x01, i.toByte(), 0x00))
        fun valid(i: Int, k: String) =
            FeatureFlagProbe.NextResponse(1, 1, i, true, k, listOf<Byte>(0x01, i.toByte(), 0x01))

        for (i in 0 until FeatureFlagProbe.MAX_CONSECUTIVE_EMPTY_SLOTS - 1) {
            assertTrue(report.noteNext(empty(i)))
        }
        assertTrue(report.noteNext(valid(20, "hr_ch_switching")))
        for (i in 21 until 21 + FeatureFlagProbe.MAX_CONSECUTIVE_EMPTY_SLOTS - 1) {
            assertTrue("the run restarted at the valid entry", report.noteNext(empty(i)))
        }
        assertNull(report.stopCode)
        assertEquals(listOf("hr_ch_switching"), report.keys)
    }

    @Test fun nonPrintableNameIsNotReportedAsAKey() {
        val record = byteArrayOf(0x01, 0x02, 0x01, 0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte())
        val frame = whoop4Response(118, payload(1, record))
        val r = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        assertNull(r.key)
        // Our decode declining a name is NOT the strap saying stop: the firmware still flagged this entry
        // valid, so the walk steps over it instead of throwing away everything after it.
        assertFalse(r.isExhausted)
        assertTrue(r.isSkippable)
    }

    /**
     * The regression this split exists for: one undecodable entry used to end the enumeration, so a list
     * with a bad byte in the middle reported only the keys BEFORE it. The first real capture is the
     * expensive one to obtain, and it is exactly the run that must not be truncated by our own strictness.
     */
    @Test fun anUndecodableEntryDoesNotHideTheKeysAfterIt() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 4))
        fun next(index: Int, key: String?) = FeatureFlagProbe.NextResponse(1, 1, index, true, key)

        assertTrue(report.noteNext(next(0, "enable_r22_packets")))
        assertTrue("a bad name must not stop the walk", report.noteNext(next(1, null)))
        assertTrue(report.noteNext(next(2, "sigproc_wear_detect")))
        assertFalse(report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0xFF, false, null)))

        assertEquals(listOf("enable_r22_packets", "sigproc_wear_detect"), report.keys)
        assertEquals(1, report.skipped)
        assertEquals("cursor exhausted (index 0xFF)", report.stopReason)
        assertTrue(report.render().contains("1 name(s) did not decode and were skipped"))
    }

    /**
     * The reply a WHOOP 5 MG actually served to end its 115/116 walk: `index = 255` and `validKey = 0` on
     * the SAME frame. Both terminator conditions fired at once, so that run cannot say which one the
     * firmware meant — and the report must say exactly that instead of picking one.
     */
    @Test fun endMarkerCarryingValidKeyZeroIsReportedAsAmbiguous() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5, FeatureFlagProbe.DEVICE_CONFIG_NAMESPACE)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 7, listOf<Byte>(0x01, 0x07, 0x00)))
        assertTrue(
            report.noteNext(
                FeatureFlagProbe.NextResponse(1, 1, 1, true, "enable_rfid", listOf<Byte>(0x01, 0x01, 0x01)),
            ),
        )
        assertFalse(
            report.noteNext(
                FeatureFlagProbe.NextResponse(
                    1, 1, 0xFF, false, null, listOf<Byte>(0x01, 0xFF.toByte(), 0x00, 0x00),
                ),
            ),
        )

        assertTrue(report.endMarkerAlsoCarriedInvalidFlag)
        assertEquals(FeatureFlagProbe.StopCode.END_MARKER, report.stopCode)
        assertTrue(report.terminatorFinding, report.terminatorFinding.startsWith("AMBIGUOUS"))
        assertTrue(
            report.terminatorFinding,
            report.terminatorFinding.contains("both terminator conditions fired at once"),
        )
        assertTrue(report.render().contains("index=0xFF AND validKey=0 on the same reply"))
    }

    /**
     * The 0xFF marker with `validKey` still true separates the two conditions the other way, and the
     * report has to be equally careful there: 0xFF alone terminated, and validKey=0 stayed untested.
     */
    @Test fun endMarkerWithValidKeyTrueSaysValidKeyZeroIsUntested() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 2, listOf<Byte>(0x01, 0x02, 0x00)))
        assertTrue(
            report.noteNext(
                FeatureFlagProbe.NextResponse(
                    1, 1, 1, true, "enable_r22_packets", listOf<Byte>(0x01, 0x01, 0x01),
                ),
            ),
        )
        assertFalse(
            report.noteNext(
                FeatureFlagProbe.NextResponse(1, 1, 0xFF, true, null, listOf<Byte>(0x01, 0xFF.toByte(), 0x01)),
            ),
        )
        assertFalse(report.endMarkerAlsoCarriedInvalidFlag)
        assertTrue(
            report.terminatorFinding,
            report.terminatorFinding.contains("validKey=0 was never served, so it is untested"),
        )
    }

    /**
     * What the 117/118 walk on a 5/MG actually did: sixteen valid, named entries and NO terminator of
     * either kind. The walk used to stop dead at the announced count and read as a complete list. It now
     * asks a bounded number of further times, and — whatever comes back — reports in the verdict itself
     * that a client-side bound ended the run.
     */
    @Test fun walkOvershootsTheAnnouncedCountSoTheStrapCanEndItsOwnList() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 3, listOf<Byte>(0x01, 0x03, 0x00)))
        var sent = 0
        var keepGoing = true
        while (keepGoing) {
            sent += 1
            keepGoing = report.noteNext(
                FeatureFlagProbe.NextResponse(
                    1, 1, sent, true, "key_$sent", listOf<Byte>(0x01, sent.toByte(), 0x01),
                ),
            )
        }
        assertEquals(3 + FeatureFlagProbe.COUNT_OVERSHOOT_ALLOWANCE, sent)
        assertEquals(FeatureFlagProbe.StopCode.ANNOUNCED_COUNT_OVERSHOOT, report.stopCode)
        assertEquals(FeatureFlagProbe.COUNT_OVERSHOOT_ALLOWANCE, report.repliesPastAnnouncedCount)
        assertTrue(
            report.verdict,
            report.verdict.contains("INCOMPLETE: the walk ended on a client-side bound"),
        )
        assertTrue(report.terminatorFinding, report.terminatorFinding.startsWith("NO TERMINATOR OBSERVED"))
        val count = report.countFinding!!
        assertTrue(count, count.contains("Keys yielded: 7"))
        assertTrue(count, count.contains("MISMATCH against the announced 3"))
        assertTrue(count, count.contains("kept answering 4 repl(ies) past its own announced count"))
    }

    // MARK: raw bytes

    /**
     * Requirement of the whole exercise: the RAW record bytes of every reply are in the report, not only
     * the fields parsed out of them. Earlier findings here had to be re-run because only parsed output
     * survived, and a parsed field cannot contradict the layout that produced it.
     */
    @Test fun everyReplyLogsItsRawRecordBytes() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x02, 0x00)))
        val s = FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!
        report.noteStart(s)
        assertEquals(listOf<Byte>(0x01, 0x02, 0x00), s.record)
        val next = whoop5Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01, 0x78, 0x00)))
        val n = FeatureFlagProbe.parseNext(next, DeviceFamily.WHOOP5).value!!
        assertTrue(report.noteNext(n))
        val text = report.render()
        assertTrue(text, text.contains("raw=01 02 00"))
        assertTrue(text, text.contains("raw=01 00 01 78 00"))
    }

    /** A reply that failed to decode is the one whose raw bytes matter most, so the whole frame goes in. */
    @Test fun undecodedReplyLogsTheWholeRawFrame() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteFailure(
            FeatureFlagProbe.ParseFailure.CRC, 118,
            byteArrayOf(0xAA.toByte(), 0x05, 0x00, 0x2B, 0x24),
        )
        assertTrue(report.render(), report.render().contains("raw frame=aa 05 00 2b 24"))
        assertEquals(FeatureFlagProbe.StopCode.PARSE_FAILURE, report.stopCode)
    }

    /**
     * The hex is bounded so one absurd record cannot flood the log — but the true LENGTH is always
     * printed, because an over-long record is itself evidence that the layout is wrong.
     */
    @Test fun overLongRawRecordIsElidedButItsLengthIsKept() {
        val long = List(FeatureFlagProbe.MAX_RAW_HEX_BYTES + 10) { 0xAB.toByte() }
        val rendered = FeatureFlagProbe.hex(long)
        assertTrue(
            rendered,
            rendered.endsWith("… (${FeatureFlagProbe.MAX_RAW_HEX_BYTES + 10} bytes total)"),
        )
        assertEquals("(empty)", FeatureFlagProbe.hex(emptyList()))
    }

    // MARK: the announced count

    /**
     * The count is read as u16 LE, and every count seen so far has had a zero high byte — where a
     * single-byte read returns the SAME number. So no capture distinguishes the two readings, and the
     * report says that rather than asserting a field width nothing has established.
     */
    @Test fun countCarriesBothReadingsAndSaysWhenTheyAgree() {
        val frame = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x10, 0x00)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(16, r.count)
        assertEquals(16, r.singleByteCount)
        assertEquals(0, r.countHighByte)
        assertTrue(r.countReadingsAgree)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(r)
        val finding = report.countFinding!!
        assertTrue(finding, finding.contains("u16 LE read = 16; single-byte read = 16 (high byte 0x00)"))
        assertTrue(finding, finding.contains("the two readings AGREE"))
    }

    /**
     * A nonzero high byte is the only thing that separates them, and it is a finding either way: on the
     * u16 reading the list is enormous, on the single-byte reading `record[2]` is padding.
     */
    @Test fun nonZeroHighByteIsReportedAsADisagreement() {
        val frame = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x07, 0x02)))
        val r = FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP5).value!!
        assertEquals(0x0207, r.count)
        assertEquals(7, r.singleByteCount)
        assertFalse(r.countReadingsAgree)
        assertFalse("an implausible u16 must not become a loop bound", r.countIsPlausible)
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(r)
        val finding = report.countFinding!!
        assertTrue(finding, finding.contains("single-byte read = 7 (high byte 0x02)"))
        assertTrue(finding, finding.contains("the two readings DISAGREE"))
    }

    /**
     * Announced-count-versus-yielded is itself a result. A strap that announces sixteen and names one has
     * fifteen entries nobody has accounted for, and the report has to raise it rather than print a tidy
     * short list.
     */
    @Test fun announcedCountVersusKeysYieldedMismatchIsReported() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 16, listOf<Byte>(0x01, 0x10, 0x00)))
        assertTrue(
            report.noteNext(
                FeatureFlagProbe.NextResponse(
                    1, 1, 1, true, "enable_r22_packets", listOf<Byte>(0x01, 0x01, 0x01),
                ),
            ),
        )
        assertFalse(
            report.noteNext(
                FeatureFlagProbe.NextResponse(1, 1, 0xFF, true, null, listOf<Byte>(0x01, 0xFF.toByte(), 0x01)),
            ),
        )
        val finding = report.countFinding!!
        assertTrue(finding, finding.contains("Keys yielded: 1"))
        assertTrue(finding, finding.contains("MISMATCH against the announced 16"))
    }

    /** …and when everything is accounted for — keys plus skipped plus empty slots — there is no alarm. */
    @Test fun fullyAccountedCountIsNotFlaggedAsAMismatch() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 3, listOf<Byte>(0x01, 0x03, 0x00)))
        report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 1, true, "a", listOf<Byte>(0x01, 0x01, 0x01)))
        report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 2, true, null, listOf<Byte>(0x01, 0x02, 0x01)))
        report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 3, false, null, listOf<Byte>(0x01, 0x03, 0x00)))
        val finding = report.countFinding!!
        assertFalse(finding, finding.contains("MISMATCH"))
        assertTrue(finding, finding.contains("Keys yielded: 1 (+1 undecodable) (+1 empty slot(s))"))
    }

    // MARK: the device-config namespace (115/116)

    /**
     * The SAME walk drives the device-config pair, so the terminator rules cannot be corrected in one
     * namespace and left wrong in the other. Decoded end-to-end from 115/116 frames.
     */
    @Test fun deviceConfigNamespaceWalksThroughTheSameCorrectedRules() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5, FeatureFlagProbe.DEVICE_CONFIG_NAMESPACE)
        val start = whoop5Response(115, payload(1, byteArrayOf(0x01, 0x02, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5, 115).value!!)
        // An empty slot first — under the old rule the walk would have ended here with zero keys.
        val hole = whoop5Response(116, payload(1, byteArrayOf(0x01, 0x02, 0x00, 0x00)))
        assertTrue(report.noteNext(FeatureFlagProbe.parseNext(hole, DeviceFamily.WHOOP5, 116).value!!))
        val named = whoop5Response(
            116, payload(1, byteArrayOf(0x01, 0x03, 0x01) + keyBytes("enable_raw_data_w_ecg")),
        )
        assertTrue(report.noteNext(FeatureFlagProbe.parseNext(named, DeviceFamily.WHOOP5, 116).value!!))
        assertEquals(
            "the key AFTER the empty slot is exactly what the old rule discarded",
            listOf("enable_raw_data_w_ecg"), report.keys,
        )

        val text = report.render()
        assertTrue(text, text.contains("#761 DEVICE-CONFIG ENUMERATION PROBE — WHOOP 5/MG"))
        assertTrue(text, text.contains("START_DEVICE_CONFIG_KEY_EXCHANGE(115) + SEND_NEXT_DEVICE_CONFIG(116)"))
        assertTrue(text, text.contains("Keys reported by the strap (1 of 2 announced"))
        assertTrue(text, text.contains("SEND_NEXT_DEVICE_CONFIG(116) → index=3"))
    }

    /** The 115/116 frames must not decode as 117/118 by accident — the opcode is checked, both ways. */
    @Test fun theTwoNamespacesDoNotDecodeEachOthersFrames() {
        val cfg = whoop5Response(116, payload(1, byteArrayOf(0x01, 0x00, 0x01)))
        assertEquals(
            FeatureFlagProbe.ParseFailure.WRONG_COMMAND,
            FeatureFlagProbe.parseNext(cfg, DeviceFamily.WHOOP5).failure,
        )
        val ff = whoop5Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01)))
        assertEquals(
            FeatureFlagProbe.ParseFailure.WRONG_COMMAND,
            FeatureFlagProbe.parseNext(ff, DeviceFamily.WHOOP5, 116).failure,
        )
        assertEquals(115, FeatureFlagProbe.DEVICE_CONFIG_NAMESPACE.startCmd)
        assertEquals(116, FeatureFlagProbe.DEVICE_CONFIG_NAMESPACE.nextCmd)
        // Still read-only: the SET verbs appear in neither namespace.
        for (ns in listOf(FeatureFlagProbe.FEATURE_FLAG_NAMESPACE, FeatureFlagProbe.DEVICE_CONFIG_NAMESPACE)) {
            assertFalse(listOf(119, 120).contains(ns.startCmd))
            assertFalse(listOf(119, 120).contains(ns.nextCmd))
        }
    }

    /**
     * An explicit refusal is the strap's answer, not one of our bounds, and it must end the walk with its
     * own name — on the START reply (where the driver reads [FeatureFlagProbeReport.hasStopped] instead of
     * stepping to 118) and on a NEXT reply alike.
     */
    @Test fun unsupportedRefusalEndsTheWalkWithItsOwnStopCode() {
        val start = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        assertFalse(start.hasStopped)
        start.noteStart(FeatureFlagProbe.StartResponse(3, 0, 0, listOf<Byte>(0x00, 0x00, 0x00)))
        assertTrue("a refused START must not step on to the next verb", start.hasStopped)
        assertEquals(FeatureFlagProbe.StopCode.UNSUPPORTED, start.stopCode)
        assertTrue(start.render().contains("Stop code: unsupported"))

        val mid = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        mid.noteStart(FeatureFlagProbe.StartResponse(1, 1, 4, listOf<Byte>(0x01, 0x04, 0x00)))
        assertTrue(
            mid.noteNext(
                FeatureFlagProbe.NextResponse(
                    1, 1, 1, true, "enable_r22_packets", listOf<Byte>(0x01, 0x01, 0x01),
                ),
            ),
        )
        assertFalse(
            mid.noteNext(
                FeatureFlagProbe.NextResponse(3, 0, 0, false, null, listOf<Byte>(0x00, 0x00, 0x00)),
            ),
        )
        assertEquals(FeatureFlagProbe.StopCode.UNSUPPORTED, mid.stopCode)
        assertEquals("a refusal is never counted as an empty slot", 0, mid.emptySlots)
        assertTrue(mid.stopReason!!, mid.stopReason!!.contains("UNSUPPORTED(3)"))
    }

    /**
     * The two platforms must classify the same reply the same way, or a strap log means different things
     * on either side. These are the exact constants the walk is bounded by.
     */
    @Test fun walkBoundsMatchTheSwiftTwin() {
        assertEquals(8, FeatureFlagProbe.MAX_CONSECUTIVE_EMPTY_SLOTS)
        assertEquals(4, FeatureFlagProbe.COUNT_OVERSHOOT_ALLOWANCE)
        assertEquals(64, FeatureFlagProbe.MAX_RAW_HEX_BYTES)
        assertEquals(128, FeatureFlagProbe.MAX_FLAGS)
        assertEquals("endMarker", FeatureFlagProbe.StopCode.END_MARKER.code)
        assertEquals("emptySlotCursorParked", FeatureFlagProbe.StopCode.EMPTY_SLOT_CURSOR_PARKED.code)
        assertEquals("emptySlotRunCap", FeatureFlagProbe.StopCode.EMPTY_SLOT_RUN_CAP.code)
        assertEquals("stepCap", FeatureFlagProbe.StopCode.STEP_CAP.code)
        assertEquals("announcedCountOvershoot", FeatureFlagProbe.StopCode.ANNOUNCED_COUNT_OVERSHOOT.code)
        assertEquals("timeout", FeatureFlagProbe.StopCode.TIMEOUT.code)
        assertEquals("unsupported", FeatureFlagProbe.StopCode.UNSUPPORTED.code)
        assertEquals("parseFailure", FeatureFlagProbe.StopCode.PARSE_FAILURE.code)
    }

    /**
     * The verdict must never blame the strap for our own decode. A firmware whose names all fail our
     * printable-ASCII/length filter DID name them; reporting "named none" points at the strap and is the
     * sentence someone would paste into #103.
     */
    @Test fun verdictBlamesOurParserNotTheStrapWhenEveryNameFails() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 3))
        for (i in 0 until 3) {
            report.noteNext(FeatureFlagProbe.NextResponse(1, 1, i, true, null))
        }
        assertTrue(report.keys.isEmpty())
        assertEquals(3, report.skipped)
        val v = report.verdict
        assertTrue(v, v.contains("strap named 3 flag(s)"))
        assertTrue(v, v.contains("our parser rejecting them"))
        assertFalse("must not report our limitation as the strap's behaviour", v.contains("named none"))
    }

    /** A partial success says so in the headline too, not only in the flag-count line. */
    @Test fun verdictReportsSkippedAlongsideTheKeysItDidGet() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 3))
        report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0, true, "enable_r22_packets"))
        report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 1, true, null))
        assertEquals(
            "enumerated 1 feature-flag key name(s); 1 further name(s) did not decode",
            report.verdict,
        )
    }

    /**
     * The skip cannot become an unbounded walk: [FeatureFlagProbe.MAX_FLAGS] still terminates a firmware
     * that answers forever with entries whose names never decode.
     */
    @Test fun everyReplyUndecodableStillStopsAtTheSafetyCap() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        var sent = 0
        while (report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0, true, null))) {
            sent += 1
            assertTrue("walk must not run away", sent < FeatureFlagProbe.MAX_FLAGS + 2)
        }
        assertEquals(FeatureFlagProbe.MAX_FLAGS, report.steps)
        assertEquals(FeatureFlagProbe.MAX_FLAGS, report.skipped)
        assertEquals("safety cap of ${FeatureFlagProbe.MAX_FLAGS} replies reached", report.stopReason)
        assertTrue(report.keys.isEmpty())
    }

    @Test fun keyLongerThanTheSetSideFieldIsRejected() {
        val long = "a".repeat(FeatureFlagProbe.MAX_KEY_LENGTH + 1)
        assertNull(FeatureFlagProbe.asciiKey(long.toByteArray(Charsets.US_ASCII) + byteArrayOf(0)))
        assertEquals("ok_key", FeatureFlagProbe.asciiKey("ok_key".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 0x41)))
    }

    @Test fun badCrcIsRejected() {
        val frame = whoop4Response(117, payload(1, byteArrayOf(0x01, 0x0B, 0x00)))
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xFF).toByte()
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).failure)

        val five = whoop5Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("x")))
        five[7] = (five[7].toInt() xor 0xFF).toByte()
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseNext(five, DeviceFamily.WHOOP5).failure)
    }

    @Test fun corruptPayloadBytesFailCrcBeforeAnyFieldIsRead() {
        val frame = whoop4Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("enable_r22_packets")))
        frame[10] = (frame[10].toInt() xor 0x01).toByte()
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).failure)
    }

    @Test fun wrongCommandIsRejected() {
        val frame = whoop4Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("x")))
        assertEquals(
            FeatureFlagProbe.ParseFailure.WRONG_COMMAND,
            FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).failure,
        )
    }

    @Test fun nonCommandResponseTypeIsRejected() {
        // Same bytes, but packet type COMMAND (35) rather than COMMAND_RESPONSE (36).
        val inner = byteArrayOf(35, 1, 117) + payload(1, byteArrayOf(0x01, 0x0B, 0x00))
        val length = inner.size + 4
        val lenBytes = byteArrayOf((length and 0xFF).toByte(), ((length shr 8) and 0xFF).toByte())
        val c = Crc.crc32(inner)
        val frame = byteArrayOf(0xAA.toByte()) + lenBytes + byteArrayOf(Crc.crc8(lenBytes).toByte()) + inner +
            byteArrayOf(
                (c and 0xFFL).toByte(), ((c shr 8) and 0xFFL).toByte(),
                ((c shr 16) and 0xFFL).toByte(), ((c shr 24) and 0xFFL).toByte(),
            )
        assertEquals(FeatureFlagProbe.ParseFailure.ENVELOPE, FeatureFlagProbe.parseStart(frame, DeviceFamily.WHOOP4).failure)
    }

    @Test fun truncatedRecordsAreRejected() {
        val short = whoop4Response(117, payload(1, byteArrayOf(0x01)))
        assertEquals(FeatureFlagProbe.ParseFailure.TRUNCATED, FeatureFlagProbe.parseStart(short, DeviceFamily.WHOOP4).failure)
        val header = whoop4Response(118, byteArrayOf(0x0A, 0x01))
        assertEquals(FeatureFlagProbe.ParseFailure.TRUNCATED, FeatureFlagProbe.parseNext(header, DeviceFamily.WHOOP4).failure)
        val full = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x02, 0x00)))
        assertEquals(
            FeatureFlagProbe.ParseFailure.CRC,
            FeatureFlagProbe.parseStart(full.copyOfRange(0, 9), DeviceFamily.WHOOP5).failure,
        )
        assertEquals(FeatureFlagProbe.ParseFailure.CRC, FeatureFlagProbe.parseStart(ByteArray(0), DeviceFamily.WHOOP4).failure)
    }

    @Test fun fullWalkRendersEveryKeyAndStopsOnTheEndMarker() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x03, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        val names = listOf("enable_r22_packets", "hr_ch_switching", "wear_detect_bias")
        names.forEachIndexed { i, name ->
            val record = byteArrayOf(0x01, i.toByte(), 0x01) + keyBytes(name)
            val frame = whoop5Response(118, payload(1, record))
            val n = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP5).value!!
            assertTrue("the announced count no longer ends the walk by itself", report.noteNext(n))
        }
        // The strap's own end marker — the only thing that ends a walk cleanly.
        val end = whoop5Response(118, payload(1, byteArrayOf(0x01, 0xFF.toByte(), 0x00, 0x00)))
        assertFalse(report.noteNext(FeatureFlagProbe.parseNext(end, DeviceFamily.WHOOP5).value!!))
        assertEquals(names, report.keys)
        assertEquals(FeatureFlagProbe.StopCode.END_MARKER, report.stopCode)
        val text = report.render()
        assertTrue(text.contains("#761 FEATURE-FLAG ENUMERATION PROBE — WHOOP 5/MG"))
        assertTrue(text.contains("Read-only"))
        assertTrue(text.contains("enumerated 3 feature-flag key name(s)"))
        assertTrue(text.contains("Flags reported by the strap (3 of 3 announced)"))
        assertTrue(text.contains("   1. enable_r22_packets"))
        assertTrue(text.contains("   3. wear_detect_bias"))
        assertTrue(text.contains("Stop code: endMarker"))
        assertTrue(text.contains("START_FF_KEY_EXCHANGE(117) → revision=1 count=3 result=SUCCESS(1)"))
        assertTrue(text.contains("SEND_NEXT_FF(118) → index=0 validKey=true key=\"enable_r22_packets\""))
    }

    @Test fun repeatedKeysCannotDriveAnUnboundedWalk() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        val record = byteArrayOf(0x01, 0x00, 0x01) + keyBytes("stuck_cursor")
        val frame = whoop4Response(118, payload(1, record))
        val n = FeatureFlagProbe.parseNext(frame, DeviceFamily.WHOOP4).value!!
        var steps = 0
        while (report.noteNext(n)) {
            steps += 1
            assertTrue("the walk must terminate", steps < FeatureFlagProbe.MAX_FLAGS + 2)
        }
        assertEquals(listOf("stuck_cursor"), report.keys)
        assertEquals(FeatureFlagProbe.MAX_FLAGS, report.steps)
        assertEquals("safety cap of 128 replies reached", report.stopReason)
    }

    @Test fun timeoutAndFailureAreReportedNotSwallowed() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteTimeout(117, 8)
        val text = report.render()
        assertTrue(text.contains("no COMMAND_RESPONSE for opcode 117 within 8s"))
        assertTrue(text.contains("no usable reply — the enumerate path is unconfirmed"))
        assertTrue(text.contains("(none)"))

        val other = FeatureFlagProbeReport(DeviceFamily.WHOOP4)
        other.noteFailure(FeatureFlagProbe.ParseFailure.CRC, 118)
        assertTrue(other.render().contains("CRC failed — frame rejected (never decoded)"))
    }

    /**
     * GOLDEN: the exact rendered report, byte-for-byte. Its Swift twin
     * (`FeatureFlagProbeTests.testGoldenReportIsByteIdenticalAcrossPlatforms`) asserts the SAME literal,
     * so a strap log reads identically on either platform — that is the parity contract, and a whitespace
     * or wording drift on one side fails here rather than in a user's log.
     */
    @Test fun goldenReportIsByteIdenticalAcrossPlatforms() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x02, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        val first = whoop5Response(118, payload(1, byteArrayOf(0x01, 0x00, 0x01) + keyBytes("enable_r22_packets")))
        assertTrue(report.noteNext(FeatureFlagProbe.parseNext(first, DeviceFamily.WHOOP5).value!!))
        val end = whoop5Response(118, payload(1, byteArrayOf(0x01, 0xFF.toByte(), 0x00, 0x00)))
        assertFalse(report.noteNext(FeatureFlagProbe.parseNext(end, DeviceFamily.WHOOP5).value!!))

        val golden = """
            #761 FEATURE-FLAG ENUMERATION PROBE — WHOOP 5/MG
            Read-only: START_FF_KEY_EXCHANGE(117) + SEND_NEXT_FF(118). No value is written; SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119) are never sent from this path.

            Verdict: enumerated 1 feature-flag key name(s)
            Stopped: cursor exhausted (index 0xFF)
            Stop code: endMarker
            Terminator: AMBIGUOUS — the walk ended on a reply carrying index=0xFF AND validKey=0 together, so both terminator conditions fired at once and this run cannot say which one the firmware meant.
            Announced count: u16 LE read = 2; single-byte read = 2 (high byte 0x00) — the two readings AGREE, so this reply does not establish the field's width. Keys yielded: 1 — MISMATCH against the announced 2

            Flags reported by the strap (1 of 2 announced):
               1. enable_r22_packets

            Exchange:
              START_FF_KEY_EXCHANGE(117) → revision=1 count=2 result=SUCCESS(1) raw=01 02 00
              SEND_NEXT_FF(118) → index=0 validKey=true key="enable_r22_packets" result=SUCCESS(1) raw=01 00 01 65 6e 61 62 6c 65 5f 72 32 32 5f 70 61 63 6b 65 74 73 00 00 00 00 00 00 00 00 00 00
              SEND_NEXT_FF(118) → index=255 validKey=false result=SUCCESS(1) raw=01 ff 00 00 00 00 00  (index=0xFF AND validKey=0 on the same reply — both terminator conditions at once)

        """.trimIndent()
        assertEquals(golden, report.render())
    }

    /**
     * The 117 answer landed and then nothing did: `probeFeatureFlags()` sends 118, the 8s timer fires,
     * and the report renders with zero SEND_NEXT replies. "Named none" would be a claim about the
     * strap's key list that this run's own inputs cannot support — the list was never read. Same class
     * as the `skipped > 0` branch beside it: never report our limitation as the strap's behaviour.
     */
    @Test fun announcedCountWithNo118ReplyIsInconclusiveNotBlamedOnTheStrap() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x05, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        report.noteTimeout(118, 8)

        assertEquals("no SEND_NEXT reply was decoded", 0, report.steps)
        val v = report.verdict
        assertEquals(
            "strap announced 5 flag(s); no SEND_NEXT_FF(118) reply was decoded — " +
                "the key list was never read (inconclusive)",
            v
        )
        assertFalse("must not report our own timeout as the strap serving no names", v.contains("named none"))
    }

    /**
     * A 118 reply that DID land and carried no name is the opposite case: the strap walked its own
     * cursor straight to the end marker, so "named none" is a fact about the strap and is said plainly.
     */
    @Test fun announcedCountWithARealEmptyWalkIsSaidPlainly() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        val start = whoop5Response(117, payload(1, byteArrayOf(0x01, 0x05, 0x00)))
        report.noteStart(FeatureFlagProbe.parseStart(start, DeviceFamily.WHOOP5).value!!)
        assertFalse(report.noteNext(FeatureFlagProbe.NextResponse(1, 1, 0xFF, false, null)))

        assertEquals(1, report.steps)
        assertTrue(report.keys.isEmpty())
        assertEquals(0, report.skipped)
        assertEquals("strap announced 5 flag(s) but named none", report.verdict)
    }

    /**
     * The count itself is the strap's claim, not a measurement. [FeatureFlagProbeReport.noteStart]
     * already marks an implausible one in the trace; the verdict is the line that gets pasted into an
     * issue, so it carries the doubt too rather than restating the number as bare fact.
     */
    @Test fun implausibleAnnouncedCountIsNotRestatedAsFactInTheVerdict() {
        val report = FeatureFlagProbeReport(DeviceFamily.WHOOP5)
        report.noteStart(FeatureFlagProbe.StartResponse(1, 1, 9999))
        report.noteTimeout(118, 8)

        val v = report.verdict
        assertTrue(v, v.contains("an implausible 9999 flag(s)"))
        assertTrue(v, v.contains("(inconclusive)"))
    }
}
