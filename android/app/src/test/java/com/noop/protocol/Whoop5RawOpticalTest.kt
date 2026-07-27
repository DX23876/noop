package com.noop.protocol

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume
import org.junit.Test
import java.io.File

/**
 * R20 (layout-v20, 2,140-byte) optical decoder — the Kotlin half of a shared Swift<->Kotlin drift guard.
 *
 * `src/test/resources/r20_optical_oracle.json` is byte-identical to
 * `Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/r20_optical_oracle.json`, and Swift's
 * `Whoop5RawOpticalTests` runs the same assertions through its own decoder. Both `hex` strings are REAL
 * captured records; the expected values came from an independent third implementation of the published
 * byte layout (issue #423), so neither platform can drift without failing. Same idiom as
 * [DecoderOracleTest].
 */
class Whoop5RawOpticalTest {

    private fun hexToBytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    private fun loadOracle(): JSONObject {
        val stream = javaClass.classLoader!!.getResourceAsStream("r20_optical_oracle.json")
        assertNotNull("r20_optical_oracle.json missing from test classpath", stream)
        return JSONObject(stream!!.bufferedReader().use { it.readText() })
    }

    private fun JSONArray.toIntList(): List<Int> = (0 until length()).map { getInt(it) }

    // MARK: - Golden vectors

    /** Every field of every block of every fixture record. This is the whole byte map executing. */
    @Test
    fun oracleRecordsDecodeToPublishedLayout() {
        val oracle = loadOracle()
        val layout = oracle.getJSONObject("layout")
        val bases = layout.getJSONArray("block_bases").toIntList()
        val headLength = layout.getInt("head_length")
        val records = oracle.getJSONArray("records")
        assertTrue("no oracle records loaded", records.length() > 0)

        for (r in 0 until records.length()) {
            val record = records.getJSONObject(r)
            val name = record.getString("name")
            val bytes = hexToBytes(record.getString("hex"))
            assertEquals("$name: length", layout.getInt("buffer_length"), bytes.size)

            val decoded = Whoop5RawOptical.decode(bytes)
            assertNotNull("$name failed to decode", decoded)
            decoded!!

            val expect = record.getJSONObject("expect")
            assertEquals("$name.layout_version", expect.getInt("layout_version"), decoded.layoutVersion)
            assertEquals("$name.record_index", expect.getLong("record_index"), decoded.recordIndex)
            assertEquals("$name.base_ts", expect.getLong("base_ts"), decoded.baseTs)
            assertEquals("$name.checksum", expect.getLong("checksum"), decoded.checksum)
            assertEquals(
                "$name.sample_counts",
                expect.getJSONArray("sample_counts").toIntList(),
                decoded.blocks.map { it.sampleCount },
            )

            val blocks = expect.getJSONArray("blocks")
            assertEquals("$name: block count", blocks.length(), decoded.blocks.size)
            for (b in 0 until blocks.length()) {
                val want = blocks.getJSONObject(b)
                val index = want.getInt("index")
                val block = decoded.blocks[index]
                val cfg = block.config
                val label = "$name.blk$index"
                assertEquals("$label.index", index, block.index)
                assertEquals("$label.sample_count", want.getInt("sample_count"), cfg.sampleCount)
                assertEquals("$label.source_a", want.getInt("source_a"), cfg.sourceA)
                assertEquals("$label.drive_a", want.getInt("drive_a"), cfg.driveA)
                assertEquals("$label.source_b", want.getInt("source_b"), cfg.sourceB)
                assertEquals("$label.drive_b", want.getInt("drive_b"), cfg.driveB)
                assertEquals("$label.detector_a_select", want.getInt("detector_a_select"), cfg.detectorASelect)
                assertEquals("$label.range_a", want.getLong("range_a"), cfg.rangeA)
                assertEquals("$label.offset_a", want.getInt("offset_a"), cfg.offsetA)
                assertEquals("$label.detector_b_select", want.getInt("detector_b_select"), cfg.detectorBSelect)
                assertEquals("$label.range_b", want.getLong("range_b"), cfg.rangeB)
                assertEquals("$label.offset_b", want.getInt("offset_b"), cfg.offsetB)
                assertEquals("$label.reserved", want.getInt("reserved"), block.reserved)
                assertEquals("$label.readings_a", want.getJSONArray("readings_a").toIntList(), block.readingsA)
                assertEquals("$label.readings_b", want.getJSONArray("readings_b").toIntList(), block.readingsB)

                // The 21-byte head is fully consumed by the eleven named fields, and the raw view
                // still round-trips.
                assertEquals("$label.rawHeader", headLength, block.rawHeader.size)
                val base = bases[index]
                assertEquals(
                    "$label: rawHeader must reproduce the on-wire head bytes",
                    (base until base + headLength).map { bytes[it].toInt() and 0xFF },
                    block.rawHeader,
                )
            }
        }
    }

    /**
     * The block pattern that defines this record: three sampling blocks and two whose entire 400-byte
     * reading area is zero. `sample_count == 0` must yield NO readings, not 50 zeros.
     */
    @Test
    fun blockPatternIsThreeActiveTwoDark() {
        val records = loadOracle().getJSONArray("records")
        for (r in 0 until records.length()) {
            val record = records.getJSONObject(r)
            val name = record.getString("name")
            val decoded = requireNotNull(Whoop5RawOptical.decode(hexToBytes(record.getString("hex"))))
            assertEquals(name, listOf(25, 0, 0, 25, 25), decoded.blocks.map { it.sampleCount })
            for (block in decoded.blocks) {
                assertEquals("$name.blk${block.index}", 2, block.channels.size)
                assertEquals("$name.blk${block.index}.a", block.sampleCount, block.readingsA.size)
                assertEquals("$name.blk${block.index}.b", block.sampleCount, block.readingsB.size)
                assertEquals("$name.blk${block.index}.reserved", 0, block.reserved)
            }
            // Block 3 is the corpus's built-in dark control: sampling, but with both drives at zero.
            assertEquals(name, 25, decoded.blocks[3].config.sampleCount)
            assertEquals(name, 0, decoded.blocks[3].config.driveA)
            assertEquals(name, 0, decoded.blocks[3].config.driveB)
        }
    }

    /**
     * Sign extension. The containers are already sign-extended on the wire, so the failure this guards
     * is a decoder that reads them unsigned or re-extends from bit 19: either turns `ab a9 ff ff` into
     * a large positive number instead of -22,101.
     */
    @Test
    fun negativeReadingsSignExtend() {
        val records = loadOracle().getJSONArray("records")
        var sawNegative = false
        for (r in 0 until records.length()) {
            val record = records.getJSONObject(r)
            val name = record.getString("name")
            val decoded = requireNotNull(Whoop5RawOptical.decode(hexToBytes(record.getString("hex"))))
            for (block in decoded.blocks) {
                for (value in block.readingsA + block.readingsB) {
                    assertTrue("$name: below the signed 20-bit floor", value >= Whoop5RawOptical.SAMPLE_MIN)
                    assertTrue("$name: above the signed 20-bit rail", value <= Whoop5RawOptical.SAMPLE_MAX)
                    if (value < 0) sawNegative = true
                }
            }
        }
        assertTrue("fixture must contain negative readings or it proves nothing", sawNegative)
        assertEquals(-524_288, Whoop5RawOptical.SAMPLE_MIN)
        assertEquals(524_287, Whoop5RawOptical.SAMPLE_MAX)

        val first = requireNotNull(
            Whoop5RawOptical.decode(hexToBytes(records.getJSONObject(0).getString("hex"))),
        )
        assertEquals(
            "wire ab a9 ff ff is -22,101; 1,048,491 or 4,294,945,195 means the sign was dropped",
            -22_101,
            first.blocks[0].readingsB.first(),
        )
    }

    /**
     * The positive rail: exactly `2^19-1`, never exceeded anywhere in the corpus. A decoder that
     * mis-sizes the container would land somewhere else entirely.
     */
    @Test
    fun saturationRailIsExactly2Pow19Minus1() {
        val records = loadOracle().getJSONArray("records")
        val record = (0 until records.length())
            .map { records.getJSONObject(it) }
            .first { it.getString("name") == "rails_saturation_and_negatives" }
        val decoded = requireNotNull(Whoop5RawOptical.decode(hexToBytes(record.getString("hex"))))
        val all = decoded.blocks.flatMap { it.readingsA + it.readingsB }
        assertEquals("positive rail", 524_287, all.max())
        assertTrue("record must actually saturate", all.count { it == 524_287 } > 0)
        assertTrue("record must also carry negatives", all.min() < 0)
    }

    /**
     * CRC gating. Bad bytes never become data: every single-bit corruption in the fixture must be
     * REJECTED, not decoded best-effort. Each case names the checksum it trips so a regression
     * identifies which gate was lost.
     */
    @Test
    fun singleBitCorruptionIsRejected() {
        val oracle = loadOracle()
        val rejection = oracle.getJSONObject("crc_rejection")
        val records = oracle.getJSONArray("records")
        val source = (0 until records.length())
            .map { records.getJSONObject(it) }
            .first { it.getString("name") == rejection.getString("source") }
        val clean = hexToBytes(source.getString("hex"))
        assertNotNull("control: the unmodified record must decode", Whoop5RawOptical.decode(clean))

        val cases = rejection.getJSONArray("cases")
        assertTrue("no rejection cases loaded", cases.length() > 0)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val corrupted = clean.copyOf()
            val off = c.getInt("offset")
            corrupted[off] = (corrupted[off].toInt() xor c.getInt("xor")).toByte()
            assertNotEquals("${c.getString("name")}: fixture flipped nothing", clean[off], corrupted[off])
            assertNull(
                "${c.getString("name")} (${c.getString("why")}) decoded despite a broken checksum",
                Whoop5RawOptical.decode(corrupted),
            )
        }
    }

    /**
     * The CRC input range, asserted directly, because the previously published value was `[26:2136]`
     * and anything built on it rejects every real record. This is the standard WHOOP 5 envelope rule.
     */
    @Test
    fun checksumCoversByte8ThroughPayloadEnd() {
        val bytes = hexToBytes(loadOracle().getJSONArray("records").getJSONObject(0).getString("hex"))
        val trailer = (0 until 4).fold(0L) { acc, i ->
            acc or ((bytes[2136 + i].toLong() and 0xFF) shl (8 * i))
        }
        assertEquals("CRC32 input is [8:2136]", trailer, Crc.crc32(bytes, 8, 2136))
        assertNotEquals("the retracted [26:2136] range must NOT match", trailer, Crc.crc32(bytes, 26, 2136))
        // Header bytes 6:7, listed as unidentified in the write-up, are the envelope's CRC16-Modbus.
        val headerCrc = (bytes[6].toInt() and 0xFF) or ((bytes[7].toInt() and 0xFF) shl 8)
        assertEquals("header CRC16-Modbus over [0:6]", headerCrc, Crc.crc16Modbus(bytes, 0, 6))
        assertTrue(
            "both checksums verify as one envelope check",
            Framing.frameCrcOk(bytes, DeviceFamily.WHOOP5),
        )
    }

    // MARK: - Full-corpus verification

    /**
     * Runs the decoder over a whole deep-buffer capture and asserts the published invariants on every
     * record — the Kotlin twin of Swift's `testFullCorpusDecodesWithPublishedInvariants`. Two golden
     * vectors prove the offsets; this proves they hold at scale, on both platforms.
     *
     * Opt-in, because the capture is far too large to commit:
     *
     * ```
     * WHOOP_R20_CORPUS=/path/to/buffers2140.jsonl ./gradlew :app:testFullDebugUnitTest \
     *   --tests '*Whoop5RawOpticalTest.fullCorpus*'
     * ```
     *
     * Verified against a 29,203-record WHOOP 5.0/MG capture: 29,203/29,203 decode, 0 mismatches.
     */
    @Test
    fun fullCorpusDecodesWithPublishedInvariants() {
        val path = System.getenv("WHOOP_R20_CORPUS")
        Assume.assumeTrue(
            "set WHOOP_R20_CORPUS to a deep-buffer JSONL to run the full-corpus check",
            path != null && File(path).exists(),
        )

        val driveSet = setOf(1150, 1400, 1750, 2200, 2750, 3350)
        var total = 0
        var decodedCount = 0
        var mismatched = 0
        val failures = mutableListOf<String>()

        File(path!!).forEachLine { line ->
            if (line.isBlank()) return@forEachLine
            val obj = JSONObject(line)
            if (obj.optInt("size", -1) != Whoop5RawOptical.BUFFER_LENGTH) return@forEachLine
            val hex = obj.optString("hex", "")
            if (hex.isEmpty()) return@forEachLine
            total++

            val frame = Whoop5RawOptical.decode(hexToBytes(hex))
            if (frame == null) {
                if (failures.size < 5) failures += "record $total failed to decode"
                return@forEachLine
            }
            decodedCount++

            val problems = mutableListOf<String>()
            // The recorder's own envelope timestamp must agree with the decoded field.
            if (obj.has("strap_ts") && frame.baseTs != obj.getLong("strap_ts")) {
                problems += "base_ts ${frame.baseTs} != strap_ts ${obj.getLong("strap_ts")}"
            }
            if (frame.blocks.map { it.sampleCount } != listOf(25, 0, 0, 25, 25)) problems += "block pattern"
            val blk0 = frame.blocks[0].config
            if (blk0.driveA !in driveSet) problems += "drive_a ${blk0.driveA} outside the six-value set"
            if (blk0.driveB != blk0.driveA * 2) problems += "drive_b != 2 * drive_a"
            for (block in frame.blocks) {
                if (block.reserved != 0) problems += "blk${block.index} reserved != 0"
                if (block.config.offsetA % 800 != 0 || block.config.offsetB % 800 != 0) {
                    problems += "blk${block.index} offset not a multiple of 800"
                }
                if (block.readingsA.size != block.sampleCount || block.readingsB.size != block.sampleCount) {
                    problems += "blk${block.index} reading count != sample_count"
                }
                val out = (block.readingsA + block.readingsB)
                    .firstOrNull { it < Whoop5RawOptical.SAMPLE_MIN || it > Whoop5RawOptical.SAMPLE_MAX }
                if (out != null) problems += "blk${block.index} sample $out outside the signed 20-bit domain"
            }
            if (problems.isNotEmpty()) {
                mismatched++
                if (failures.size < 5) failures += "record $total: ${problems.joinToString(", ")}"
            }
        }

        println("R20 corpus: $decodedCount/$total decoded, $mismatched invariant mismatches")
        assertTrue("no 2,140-byte records found in $path", total > 0)
        assertEquals("every record must decode. first failures: $failures", total, decodedCount)
        assertEquals("published invariants must hold on every record: $failures", 0, mismatched)
    }

    // MARK: - Structural gates

    @Test
    fun rejectsWrongShapeOrImpossibleCount() {
        assertNotNull(Whoop5RawOptical.decode(sealedSyntheticFrame()))

        // A sample count beyond the 50-slot capacity cannot be honoured, even with valid checksums.
        assertNull(
            Whoop5RawOptical.decode(
                reseal(
                    sealedSyntheticFrame().also {
                        it[Whoop5RawOptical.BLOCK_START] = (Whoop5RawOptical.CHANNEL_CAPACITY + 1).toByte()
                    },
                ),
            ),
        )
        // Wrong length, wrong record class, wrong layout version.
        assertNull(Whoop5RawOptical.decode(sealedSyntheticFrame() + byteArrayOf(0)))
        assertNull(Whoop5RawOptical.decode(reseal(sealedSyntheticFrame().also { it[8] = 0x2E })))
        assertNull(Whoop5RawOptical.decode(reseal(sealedSyntheticFrame().also { it[9] = 21 })))
    }

    /**
     * The Swift and Android copies of the oracle MUST be byte-identical, so neither platform can edit
     * its fixture without the other. Skips when the Swift tree is not present in this checkout.
     */
    @Test
    fun oracleCopiesAreIdentical() {
        val android = File("src/test/resources/r20_optical_oracle.json")
        val swift = File("../Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/r20_optical_oracle.json")
        if (!android.exists() || !swift.exists()) return
        assertTrue(
            "r20_optical_oracle.json copies differ — keep Swift and Android in lockstep",
            android.readBytes().contentEquals(swift.readBytes()),
        )
    }

    // MARK: - Synthetic frame helpers

    /**
     * A minimal, structurally valid, checksum-sealed v20 frame. Sealing is not optional any more: the
     * decoder CRC-gates, so a hand-built frame has to carry real checksums exactly like a strap's.
     */
    private fun sealedSyntheticFrame(): ByteArray =
        reseal(
            ByteArray(Whoop5RawOptical.BUFFER_LENGTH).also {
                it[0] = 0xAA.toByte()
                it[1] = 0x01
                it[2] = 0x54 // declared length 2132 = 2140 - 8
                it[3] = 0x08
                it[4] = 0x01
                it[8] = Whoop5RawOptical.RECORD_CLASS.toByte()
                it[9] = Whoop5RawOptical.LAYOUT_VERSION.toByte()
            },
        )

    /** Recompute both checksums after mutating a frame, so a test asserts the gate it means to. */
    private fun reseal(frame: ByteArray): ByteArray {
        if (frame.size < 12) return frame
        val headerCrc = Crc.crc16Modbus(frame, 0, 6)
        frame[6] = (headerCrc and 0xFF).toByte()
        frame[7] = ((headerCrc shr 8) and 0xFF).toByte()
        val end = Whoop5RawOptical.CHECKSUM_OFFSET
        if (frame.size < end + 4) return frame
        val payloadCrc = Crc.crc32(frame, 8, end)
        for (i in 0 until 4) frame[end + i] = ((payloadCrc shr (8 * i)) and 0xFF).toByte()
        return frame
    }
}
