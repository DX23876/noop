package com.noop.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #891/#1100: the type-43 REALTIME_RAW_DATA sample decoder.
 *
 * These offsets used to be written out three times in the app layer — live view, signal classifier, waveform
 * export — so the three could disagree about the same record and none of them was testable without a strap.
 * They now live in [Whoop5Ecg]; this pins the layout, the sign handling, and the ONE signal-present rule.
 */
class Whoop5EcgRawRecordTest {

    /** A 240-byte record with [samples] written i16-LE from the waveform offset. */
    private fun rawRecord(samples: IntArray = IntArray(0), type: Int = PacketType.REALTIME_RAW_DATA.rawValue): ByteArray {
        val f = ByteArray(Whoop5Ecg.RAW_RECORD_LENGTH)
        f[Whoop5Ecg.RAW_TYPE_OFFSET] = type.toByte()
        var i = Whoop5Ecg.RAW_WAVEFORM_START
        for (v in samples) {
            if (i + 1 >= Whoop5Ecg.RAW_BODY_END) break
            f[i] = (v and 0xFF).toByte()
            f[i + 1] = ((v shr 8) and 0xFF).toByte()
            i += 2
        }
        return f
    }

    @Test
    fun theRecordCarriesExactly101Samples() {
        // Load-bearing beyond arithmetic: this is the lag the BPM estimator has to refuse.
        assertEquals(101, Whoop5Ecg.SAMPLES_PER_RAW_RECORD)
        assertEquals(101, Whoop5Ecg.realtimeRawSamples(rawRecord())!!.size)
    }

    @Test
    fun onlyA240ByteType43FrameIsARawRecord() {
        assertTrue(Whoop5Ecg.isRealtimeRawRecord(rawRecord()))
        // Wrong type byte, right length.
        assertFalse(Whoop5Ecg.isRealtimeRawRecord(rawRecord(type = 0x2F)))
        // Right type byte, wrong length.
        assertFalse(Whoop5Ecg.isRealtimeRawRecord(rawRecord().copyOf(200)))
        assertNull(Whoop5Ecg.realtimeRawSamples(rawRecord(type = 0x2F)))
        assertNull(Whoop5Ecg.realtimeRawBodyNonZeroBytes(ByteArray(4)))
        assertNull(Whoop5Ecg.realtimeRawSignalPresent(ByteArray(0)))
    }

    @Test
    fun samplesAreSignedLittleEndian() {
        val injected = intArrayOf(0, 1, -1, 32767, -32768, 258, -258)
        val got = Whoop5Ecg.realtimeRawSamples(rawRecord(injected))!!
        assertArrayEquals(injected, got.copyOf(injected.size))
        // Everything past what was written stays zero rather than being trimmed away.
        assertEquals(0, got[injected.size])
    }

    @Test
    fun zeroSamplesAreKeptNotTrimmed() {
        // A trailing run of zeros in a real record is evidence about the record. The export used to strip
        // it, which silently edited the artifact.
        val got = Whoop5Ecg.realtimeRawSamples(rawRecord(intArrayOf(50, 0, 0, 0)))!!
        assertEquals(101, got.size)
        assertEquals(50, got[0])
        assertTrue(got.drop(1).all { it == 0 })
    }

    @Test
    fun signalPresentIsOneRuleSharedByEveryConsumer() {
        // A record of pure baseline: no body bytes set at all.
        assertEquals(0, Whoop5Ecg.realtimeRawBodyNonZeroBytes(rawRecord()))
        assertFalse(Whoop5Ecg.realtimeRawSignalPresent(rawRecord())!!)

        // Just AT the threshold is still not "present" — the rule is strictly greater.
        val atThreshold = rawRecord()
        for (i in 0 until Whoop5Ecg.RAW_BODY_ACTIVE_NONZERO_BYTES) atThreshold[Whoop5Ecg.RAW_BODY_START + i] = 7
        assertEquals(Whoop5Ecg.RAW_BODY_ACTIVE_NONZERO_BYTES, Whoop5Ecg.realtimeRawBodyNonZeroBytes(atThreshold))
        assertFalse(Whoop5Ecg.realtimeRawSignalPresent(atThreshold)!!)

        val overThreshold = atThreshold.copyOf()
        overThreshold[Whoop5Ecg.RAW_BODY_START + Whoop5Ecg.RAW_BODY_ACTIVE_NONZERO_BYTES] = 7
        assertTrue(Whoop5Ecg.realtimeRawSignalPresent(overThreshold)!!)
    }

    @Test
    fun theSubHeaderIsCountedForFillButNeverDecodedAsWaveform() {
        // Bytes 24..33 are a constant sub-header: they count toward "is this record filled" but must not
        // appear in the sample series, or the trace opens with five bogus spikes every record.
        val f = rawRecord()
        for (i in Whoop5Ecg.RAW_BODY_START until Whoop5Ecg.RAW_WAVEFORM_START) f[i] = 0x7F
        assertEquals(
            Whoop5Ecg.RAW_WAVEFORM_START - Whoop5Ecg.RAW_BODY_START,
            Whoop5Ecg.realtimeRawBodyNonZeroBytes(f),
        )
        assertTrue(Whoop5Ecg.realtimeRawSamples(f)!!.all { it == 0 })
    }
}
