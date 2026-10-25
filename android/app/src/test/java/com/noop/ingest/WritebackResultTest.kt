package com.noop.ingest

import com.noop.ui.NoopPrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure coverage for the Health Connect writeback OUTCOME model (#660): the `ok` flag and the PII-safe
 * status-code mapping the writer persists for the Data Sources UI. No Android context — this is the
 * logic that decides whether a share looked healthy or silently failed.
 */
class WritebackResultTest {

    @Test
    fun ok_isTrueOnlyWhenThereAreNoFailures() {
        assertTrue(WritebackResult(written = 12, failures = emptyList()).ok)
        assertTrue(WritebackResult(written = 0, failures = emptyList()).ok)   // nothing to share is still OK
        assertFalse(WritebackResult(0, listOf(WritebackFailure.REMOTE_ERROR)).ok)
        assertFalse(WritebackResult(5, listOf(WritebackFailure.PERMISSION_DENIED)).ok)  // partial write still failed
    }

    @Test
    fun statusCode_permissionDeniedOutranksGenericError() {
        // A revoked permission needs the distinct "re-grant" action, so it wins even when a generic
        // error is also present in the same attempt.
        val mixed = WritebackResult(0, listOf(WritebackFailure.REMOTE_ERROR, WritebackFailure.PERMISSION_DENIED))
        assertEquals("PERMISSION_DENIED", mixed.statusCode)
    }

    @Test
    fun statusCode_mapsEachOutcome() {
        assertEquals("OK", WritebackResult(3, emptyList()).statusCode)
        assertEquals("REMOTE_ERROR", WritebackResult(0, listOf(WritebackFailure.REMOTE_ERROR)).statusCode)
        assertEquals("PERMISSION_DENIED", WritebackResult(0, listOf(WritebackFailure.PERMISSION_DENIED)).statusCode)
    }

    /** The code strings cross into the UI as [NoopPrefs] constants; pin them equal so the writer's
     *  persisted status and the Data Sources `when` branches can never drift apart. */
    @Test
    fun statusCode_matchesTheUiConstants() {
        assertEquals(NoopPrefs.HC_WB_OK, WritebackResult(1, emptyList()).statusCode)
        assertEquals(NoopPrefs.HC_WB_REMOTE_ERROR, WritebackResult(0, listOf(WritebackFailure.REMOTE_ERROR)).statusCode)
        assertEquals(NoopPrefs.HC_WB_PERMISSION_DENIED, WritebackResult(0, listOf(WritebackFailure.PERMISSION_DENIED)).statusCode)
    }
}
