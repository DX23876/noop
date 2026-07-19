package com.noop.protocol

/** A single raw readout channel in a WHOOP 5/MG layout-v20 optical block. */
data class RawOpticalChannel(
    /** Seven raw per-channel header bytes. No register or wavelength semantics are asserted. */
    val metadata: List<Int>,
    /** Signed ADC containers, limited by the block's sample-count byte. */
    val samples: List<Int>,
)

/** One of the five repeated 422-byte blocks in a layout-v20 record. */
data class Whoop5OpticalBlock(
    val index: Int,
    val sampleCount: Int,
    /** Header bytes 1..6, shared by both channel slots. */
    val sharedMetadata: List<Int>,
    /** Always two slots, including when [sampleCount] is zero. */
    val channels: List<RawOpticalChannel>,
    /** Final byte of the block; zero throughout the current capture corpus. */
    val reserved: Int,
) {
    val rawHeader: List<Int>
        get() = listOf(sampleCount) + sharedMetadata + channels.flatMap { it.metadata }
}

data class Whoop5OpticalFrame(
    val recordIndex: Long,
    val baseTs: Long,
    val blocks: List<Whoop5OpticalBlock>,
)

/**
 * Structural decoder for WHOOP 5/MG historical layout v20 (exactly 2,140 bytes).
 *
 * The body is five repetitions of:
 *
 * `21-byte header | 200-byte channel slot 0 | 200-byte channel slot 1 | 1 reserved byte`.
 *
 * Header byte zero is the shared sample count (0..50). The remaining bytes are kept as neutral raw
 * metadata. In the 29,203-record corpus used to establish this layout, counts are always
 * `[25, 0, 0, 25, 25]`; active slots contain 25 sign-extended i32 readings followed by zero padding.
 * The two slots under one header must not be named as two wavelengths without independent evidence.
 *
 * RE notes (issue #423, NOT authoritative): the record's config header carries an LED-current field @28
 * and per-photodiode offset DACs @38/@45. Under the split above those land as ONE drive current in a
 * block's shared bytes (@27..32 for block 0) and ONE offset DAC in each of its two 7-byte channel
 * descriptors (@33..39 and @40..46) — one LED per block, one detector per channel, which aligns with the
 * "two readout channels share one measurement config" model. Kotlin twin of the Swift note.
 */
object Whoop5RawOptical {
    const val BUFFER_LENGTH = 2140
    const val BLOCK_COUNT = 5
    const val BLOCK_START = 26
    const val BLOCK_LENGTH = 422
    const val HEADER_LENGTH = 21
    const val CHANNEL_SLOT_LENGTH = 200
    const val CHANNEL_CAPACITY = 50

    fun decode(frame: ByteArray): Whoop5OpticalFrame? {
        if (frame.size != BUFFER_LENGTH || frame.u8(0) != 0xAA ||
            frame.u8(8) != 0x2F || frame.u8(9) != 20
        ) return null

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
            )
        }

        return Whoop5OpticalFrame(
            recordIndex = frame.u32(11),
            baseTs = frame.u32(15),
            blocks = blocks,
        )
    }

    private fun ByteArray.u8(offset: Int): Int = this[offset].toInt() and 0xFF

    private fun ByteArray.u32(offset: Int): Long =
        (u8(offset).toLong() or
            (u8(offset + 1).toLong() shl 8) or
            (u8(offset + 2).toLong() shl 16) or
            (u8(offset + 3).toLong() shl 24))

    private fun ByteArray.i32(offset: Int): Int =
        u8(offset) or (u8(offset + 1) shl 8) or
            (u8(offset + 2) shl 16) or (u8(offset + 3) shl 24)
}
