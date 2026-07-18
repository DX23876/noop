package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Whoop5RawOpticalTest {
    private fun frame(): ByteArray = ByteArray(Whoop5RawOptical.BUFFER_LENGTH).also {
        it[0] = 0xAA.toByte()
        it[8] = 0x2F
        it[9] = 20
        putU32(it, 11, 11_494_060)
        putU32(it, 15, 1_784_054_004)

        val block = Whoop5RawOptical.BLOCK_START + 4 * Whoop5RawOptical.BLOCK_LENGTH
        it[block] = 2
        listOf(2, 200, 0, 4, 0, 0).forEachIndexed { i, value -> it[block + 1 + i] = value.toByte() }
        listOf(3, 32, 0, 0, 0, 0, 0).forEachIndexed { i, value -> it[block + 7 + i] = value.toByte() }
        listOf(1, 32, 0, 0, 0, 0, 0).forEachIndexed { i, value -> it[block + 14 + i] = value.toByte() }
        putI32(it, block + Whoop5RawOptical.HEADER_LENGTH, -123_456)
        putI32(it, block + Whoop5RawOptical.HEADER_LENGTH + 4, 234_567)
        putI32(it, block + Whoop5RawOptical.HEADER_LENGTH + Whoop5RawOptical.CHANNEL_SLOT_LENGTH, 9_876)
        putI32(it, block + Whoop5RawOptical.HEADER_LENGTH + Whoop5RawOptical.CHANNEL_SLOT_LENGTH + 4, 11_318)
    }

    @Test fun decodesRepeatedBlockAndPairedChannels() {
        val decoded = requireNotNull(Whoop5RawOptical.decode(frame()))
        assertEquals(11_494_060L, decoded.recordIndex)
        assertEquals(1_784_054_004L, decoded.baseTs)
        assertEquals(listOf(0, 0, 0, 0, 2), decoded.blocks.map { it.sampleCount })

        val block = decoded.blocks[4]
        assertEquals(listOf(2, 200, 0, 4, 0, 0), block.sharedMetadata)
        assertEquals(listOf(3, 32, 0, 0, 0, 0, 0), block.channels[0].metadata)
        assertEquals(listOf(1, 32, 0, 0, 0, 0, 0), block.channels[1].metadata)
        assertEquals(listOf(-123_456, 234_567), block.channels[0].samples)
        assertEquals(listOf(9_876, 11_318), block.channels[1].samples)
        assertEquals(21, block.rawHeader.size)
        assertTrue(decoded.blocks.all { it.channels.size == 2 })
    }

    @Test fun rejectsWrongShapeOrImpossibleCount() {
        assertNull(Whoop5RawOptical.decode(frame() + byteArrayOf(0)))
        assertNull(Whoop5RawOptical.decode(frame().also { it[9] = 21 }))
        assertNull(Whoop5RawOptical.decode(frame().also {
            it[Whoop5RawOptical.BLOCK_START] = (Whoop5RawOptical.CHANNEL_CAPACITY + 1).toByte()
        }))
    }

    private fun putU32(frame: ByteArray, offset: Int, value: Int) {
        frame[offset] = value.toByte()
        frame[offset + 1] = (value ushr 8).toByte()
        frame[offset + 2] = (value ushr 16).toByte()
        frame[offset + 3] = (value ushr 24).toByte()
    }

    private fun putI32(frame: ByteArray, offset: Int, value: Int) = putU32(frame, offset, value)
}
