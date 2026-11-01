package com.noop.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Fork (DX23876): the kept Room file goes 30 days after a successful adoption, not before. */
class CoreRoomAdoptionTest {
    @Test
    fun theKeptRoomFileGoesAfterThirtyDays() {
        val adopted = 1_760_000_000_000L
        assertFalse(CoreRoomAdoption.shouldDeleteLegacy(adopted, adopted + CoreRoomAdoption.KEEP_MS - 1))
        assertTrue(CoreRoomAdoption.shouldDeleteLegacy(adopted, adopted + CoreRoomAdoption.KEEP_MS))
    }
}
