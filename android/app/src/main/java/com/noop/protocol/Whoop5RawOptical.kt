package com.noop.protocol

/**
 * The eleven fields of a block's 21-byte head, in wire order. Kotlin twin of Swift's
 * `Whoop5OpticalBlockConfig`.
 *
 * Names match the public write-up in issue #423 one-for-one, so code and published record agree:
 * `sample_count, source_a, drive_a, source_b, drive_b, detector_a_select, range_a, offset_a,
 * detector_b_select, range_b, offset_b`. They describe what each field is observed to DO in NOOP's
 * own capture and assert nothing about registers, units, or emitted wavelength.
 *
 * Widths are unsigned on the wire; Kotlin has no convenient unsigned types here, so `driveA`/`driveB`
 * (u16) and `rangeA`/`rangeB` (u32) are widened to `Int`/`Long` and always carry only their real bits.
 * `offsetA`/`offsetB` are genuinely signed 16-bit.
 */
data class Whoop5OpticalBlockConfig(
    /** rel 0, u8. Readings populated in EACH slot; 0..50. `[25, 0, 0, 25, 25]` across the corpus. */
    val sampleCount: Int,
    /** rel 1, u8. Emitter selector for the block's first drive field. Meaning of {1,2,3,4} unknown. */
    val sourceA: Int,
    /** rel 2:3, u16 LE. Six values in 29,203/29,203 block-0 records: {1150,1400,1750,2200,2750,3350}. */
    val driveA: Int,
    /** rel 4, u8. Emitter selector for the second drive field; 4 in every block of every record. */
    val sourceB: Int,
    /** rel 5:6, u16 LE. `driveB == 2 * driveA` in 29,203/29,203 block-0 records; 0 in blocks 1..4. */
    val driveB: Int,
    /** rel 7, u8. Detector routing for slot A. Differs from [detectorBSelect] in every block. */
    val detectorASelect: Int,
    /** rel 8:11, u32 LE. 32, or 16 in block 1; the three high bytes are zero in every record. */
    val rangeA: Long,
    /** rel 12:13, i16 LE. Always a multiple of 800, from {0, 800, 1600, 2400}. Units unknown. */
    val offsetA: Int,
    /** rel 14, u8. Detector routing for slot B. */
    val detectorBSelect: Int,
    /** rel 15:18, u32 LE. Mirrors [rangeA]'s domain. */
    val rangeB: Long,
    /** rel 19:20, i16 LE. Mirrors [offsetA]'s domain. */
    val offsetB: Int,
)

/** A single raw readout channel in a WHOOP 5/MG layout-v20 optical block. */
data class RawOpticalChannel(
    /**
     * Seven raw per-channel header bytes, retained so the 21-byte head round-trips losslessly. The
     * named reading of these bytes is on the block's [Whoop5OpticalBlock.config].
     */
    val metadata: List<Int>,
    /** Signed ADC containers, limited by the block's sample-count byte. */
    val samples: List<Int>,
)

/** One of the five repeated 422-byte blocks in a layout-v20 record. */
data class Whoop5OpticalBlock(
    val index: Int,
    val sampleCount: Int,
    /** Header bytes 1..6, shared by both reading slots. Named reading on [config]. */
    val sharedMetadata: List<Int>,
    /** Always two slots, including when [sampleCount] is zero. */
    val channels: List<RawOpticalChannel>,
    /** Final byte of the block; zero in 29,203/29,203 records of every block. */
    val reserved: Int,
    /**
     * The named reading of the 21 head bytes. Derived from exactly the bytes above — [rawHeader]
     * stays the authoritative lossless view; this is the interpretation of it.
     */
    val config: Whoop5OpticalBlockConfig,
) {
    val rawHeader: List<Int>
        get() = listOf(sampleCount) + sharedMetadata + channels.flatMap { it.metadata }

    /** Slot A readings — `readings_a` in the #423 write-up. Empty when [sampleCount] is zero. */
    val readingsA: List<Int> get() = channels.getOrNull(0)?.samples ?: emptyList()

    /** Slot B readings — `readings_b` in the #423 write-up. Empty when [sampleCount] is zero. */
    val readingsB: List<Int> get() = channels.getOrNull(1)?.samples ?: emptyList()
}

data class Whoop5OpticalFrame(
    /** u32 LE @11. Advances +1 per record; the corpus's 1 Hz clock. */
    val recordIndex: Long,
    /** u32 LE @15. Equals the recorder's own `strap_ts` in 29,203/29,203 records. */
    val baseTs: Long,
    val blocks: List<Whoop5OpticalBlock>,
    /** u8 @9. 20 for this record type (21 is the IMU record, 18 the older frame). */
    val layoutVersion: Int = Whoop5RawOptical.LAYOUT_VERSION,
    /** u32 LE @2136 — the frame's CRC32 trailer, verified before any field above was read. */
    val checksum: Long = 0L,
)

/**
 * Decoder for WHOOP 5.0/MG historical layout v20 ("R20", exactly 2,140 bytes). Kotlin twin of Swift's
 * `Whoop5RawOptical` — the two are independent implementations of one byte layout and are held to
 * byte-equality by the shared `r20_optical_oracle.json` fixture.
 *
 * ```
 * [ 26-byte header ][ 5 x 422-byte block ][ 4-byte CRC32 ]
 *    0..25            26 448 870 1292 1714     2136..2139
 * ```
 *
 * `26 + 5*422 = 2136`. Each block is `21-byte head | 200-byte slot A | 200-byte slot B | 1 reserved`.
 * The head is fully accounted for by eleven fields (`1+1+2+1+2+1+4+2+1+4+2 = 21`) with no residue.
 * Both detector groups are 7 bytes with the identical internal shape `select:1, range:4, offset:2`,
 * which is what makes the 7-byte stride visible in a raw hex dump of block 0.
 *
 * PROVENANCE. Every offset, width, endianness and value set was measured from NOOP's own BLE captures:
 * 29,203 records of this type recorded by the #454 deep-buffer recorder from a WHOOP 5.0/MG on fw
 * 50.40.1.0, with 54 structural assertions passing on all 29,203 and 2140/2140 bytes accounted for.
 * The derivation, negative controls and refuted alternatives are published at issue #423.
 *
 * WHAT IS *NOT* CLAIMED. `drive*` is named only because a block with both drive fields at zero produces
 * a dark measurement with no pulse (block 3, the corpus's built-in negative control); its units are not
 * established. `source*` values {1,2,3,4} select something, but what each selects is unknown, and
 * NOTHING in the corpus identifies an emission band. The two slots under one head belong to ONE shared
 * measurement configuration and must not be labelled as two wavelengths.
 *
 * Baseline configuration over the corpus (constant unless marked *varies*):
 *
 * ```
 * |                 | blk0     | blk1  | blk2 | blk3 | blk4 |
 * | sampleCount     | 25       | 0     | 0    | 25   | 25   |
 * | sourceA         | 1        | 3     | 2    | 2    | 2    |
 * | driveA          | *varies* | 12750 | 6650 | 0    | 200  |  {1150,1400,1750,2200,2750,3350}
 * | sourceB         | 4        | 4     | 4    | 4    | 4    |
 * | driveB          | 2*driveA | 0     | 0    | 0    | 0    |
 * | detectorASelect | 3        | 1     | 1    | 3    | 3    |
 * | rangeA          | 32       | 16    | 32   | 32   | 32   |
 * | offsetA         | *varies* | 0     | 1600 | 0    | 0    |  {0,800,1600,2400}
 * | detectorBSelect | 4        | 2     | 2    | 4    | 1    |
 * | rangeB          | 32       | 16    | 32   | 32   | 32   |
 * | offsetB         | *varies* | 0     | 2400 | 0    | 0    |  {0,800,1600,2400}
 * ```
 */
object Whoop5RawOptical {
    const val BUFFER_LENGTH = 2140
    const val BLOCK_COUNT = 5
    const val BLOCK_START = 26
    const val BLOCK_LENGTH = 422
    const val HEADER_LENGTH = 21
    const val CHANNEL_SLOT_LENGTH = 200
    const val CHANNEL_CAPACITY = 50

    /** u8 @9 identifying this record layout. */
    const val LAYOUT_VERSION = 20

    /** u8 @8. Shared by the v18, v20 and v21 record types; also where the CRC32 input starts. */
    const val RECORD_CLASS = 0x2F

    /** Offset of the u32 LE CRC32 trailer. Also the end of the block tiling: `26 + 5*422`. */
    const val CHECKSUM_OFFSET = 2136

    /**
     * Observed ADC domain: signed 20-bit. The maximum over all 730,075 block-0 slot-A samples in the
     * corpus is EXACTLY `2^19-1`, reached in 1.57% of them and never exceeded — a hardware saturation
     * rail. Nothing ever goes below `-2^19` (deepest observed: -148,044).
     */
    const val SAMPLE_MAX = 524_287
    const val SAMPLE_MIN = -524_288

    /**
     * Decode a complete layout-v20 historical record, or null.
     *
     * CRC-GATED. Bad bytes never become data: the frame's envelope and BOTH checksums are verified
     * before a single payload field is read, and a frame that fails is rejected outright rather than
     * decoded "best effort".
     *
     * The checksum rule for this record is the ordinary WHOOP 5.0 envelope rule the repo already
     * implements — there is no v20-specific CRC:
     *
     * ```
     * crc16Modbus(frame[0 until 6]) == u16 LE @6     (29,203/29,203)
     * crc32(frame[8 until 2136])    == u32 LE @2136  (29,203/29,203)
     * ```
     *
     * [Framing.frameCrcOk] with [DeviceFamily.WHOOP5] computes exactly that, because @2:3 declares
     * 2132 and the envelope's payload span is `[8, declaredLength+8-4)` = `[8, 2136)`.
     *
     * CORRECTION TO THE PUBLISHED RECORD: an earlier note in issue #423 gave the CRC32 input as
     * `[26:2136]`. That is wrong. It is `[8:2136]` — from the record-class byte, not from the start of
     * the block tiling. Corroborated independently at a different frame size by @digitalerdude's v26
     * result (CRC-32 over bytes 8..83 for all 1,080 of their records), so byte 8 is the frame-family
     * rule rather than a v20 quirk. Anything built against `[26:2136]` rejects every real record.
     */
    fun decode(frame: ByteArray): Whoop5OpticalFrame? {
        if (frame.size != BUFFER_LENGTH || frame.u8(0) != 0xAA) return null
        if (!Framing.frameCrcOk(frame, DeviceFamily.WHOOP5)) return null
        if (frame.u8(8) != RECORD_CLASS || frame.u8(9) != LAYOUT_VERSION) return null

        val blocks = ArrayList<Whoop5OpticalBlock>(BLOCK_COUNT)
        for (index in 0 until BLOCK_COUNT) {
            val start = BLOCK_START + index * BLOCK_LENGTH
            val sampleCount = frame.u8(start)
            if (sampleCount !in 0..CHANNEL_CAPACITY) return null

            val sharedMetadata = (start + 1 until start + 7).map { frame.u8(it) }
            val channels = ArrayList<RawOpticalChannel>(2)
            for (channelIndex in 0..1) {
                val metadataStart = start + 7 + channelIndex * 7
                val metadata = (metadataStart until metadataStart + 7).map { frame.u8(it) }
                val sampleStart = start + HEADER_LENGTH + channelIndex * CHANNEL_SLOT_LENGTH
                val samples = (0 until sampleCount).map { frame.i32(sampleStart + it * 4) }
                channels += RawOpticalChannel(metadata = metadata, samples = samples)
            }
            blocks += Whoop5OpticalBlock(
                index = index,
                sampleCount = sampleCount,
                sharedMetadata = sharedMetadata,
                channels = channels,
                reserved = frame.u8(start + BLOCK_LENGTH - 1),
                config = Whoop5OpticalBlockConfig(
                    sampleCount = sampleCount,
                    sourceA = frame.u8(start + 1),
                    driveA = frame.u16(start + 2),
                    sourceB = frame.u8(start + 4),
                    driveB = frame.u16(start + 5),
                    detectorASelect = frame.u8(start + 7),
                    rangeA = frame.u32(start + 8),
                    offsetA = frame.i16(start + 12),
                    detectorBSelect = frame.u8(start + 14),
                    rangeB = frame.u32(start + 15),
                    offsetB = frame.i16(start + 19),
                ),
            )
        }

        return Whoop5OpticalFrame(
            recordIndex = frame.u32(11),
            baseTs = frame.u32(15),
            blocks = blocks,
            layoutVersion = frame.u8(9),
            checksum = frame.u32(CHECKSUM_OFFSET),
        )
    }

    private fun ByteArray.u8(offset: Int): Int = this[offset].toInt() and 0xFF

    private fun ByteArray.u16(offset: Int): Int = u8(offset) or (u8(offset + 1) shl 8)

    private fun ByteArray.i16(offset: Int): Int = u16(offset).toShort().toInt()

    private fun ByteArray.u32(offset: Int): Long =
        (u8(offset).toLong() or
            (u8(offset + 1).toLong() shl 8) or
            (u8(offset + 2).toLong() shl 16) or
            (u8(offset + 3).toLong() shl 24))

    /**
     * Readings are signed 20-bit values already SIGN-EXTENDED into a 4-byte little-endian container,
     * so a plain signed 32-bit read is the whole decode — no masking, no manual sign extension.
     *
     * This is measured, not assumed: across all 4,380,450 populated containers in the corpus the
     * fourth byte is only ever 0x00 (4,057,474) or 0xFF (322,976), never anything else, and the decoded
     * values span [-148,044, 524,287] — inside the signed 20-bit domain with the positive rail exactly
     * on `2^19-1`.
     *
     * The trap: masking to 20 bits and zero-extending, or reading the container unsigned, turns the
     * real sample `-22,101` (wire `ab a9 ff ff`) into `1,048,491` or `4,294,945,195`. Both are wrong,
     * and neither is obviously wrong from the numbers alone.
     */
    private fun ByteArray.i32(offset: Int): Int =
        u8(offset) or (u8(offset + 1) shl 8) or
            (u8(offset + 2) shl 16) or (u8(offset + 3) shl 24)
}
