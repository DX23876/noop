package com.noop.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EndpointScopedProgressStoreTest {
    @Test fun endpointChangeIsolatesProgressWhileSameEndpointCanRotateToken() = runBlocking {
        val underlying = MemoryProgress()
        val first = EndpointScopedProgressStore(underlying, "endpoint-a")
        val sameUrlNewToken = EndpointScopedProgressStore(underlying, "endpoint-a")
        val changedUrl = EndpointScopedProgressStore(underlying, "endpoint-b")
        val cursor = PushCursor(42, "natural-key")
        val window = PushWindow("2026-08-05", "2026-08-18", 1L, 2L)
        val windowProgress = PushWindowProgress(window, "batch", mapOf("2026-08-18" to "a".repeat(64)))

        first.saveCursor(PushAppendTable.HR_SAMPLE, "strap", cursor)
        first.saveWindow(PushMutableTable.JOURNAL, "strap", windowProgress)

        assertEquals(cursor, sameUrlNewToken.cursor(PushAppendTable.HR_SAMPLE, "strap"))
        assertEquals(windowProgress, sameUrlNewToken.window(PushMutableTable.JOURNAL, "strap"))
        assertNull(changedUrl.cursor(PushAppendTable.HR_SAMPLE, "strap"))
        assertNull(changedUrl.window(PushMutableTable.JOURNAL, "strap"))
    }
}
