package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Which id this process works under once the registry has changed beneath it (#53, finding 2).
 */
class ActiveDeviceResolutionTest {

    /** The merge leaves one surviving entry; the process must move onto it, not keep the emptied one. */
    @Test
    fun `the registry wins when it names a device`() {
        assertEquals("whoop-ABC", ActiveDeviceResolution.resolve("whoop-ABC", inUse = "my-whoop"))
    }

    /** A fresh install, or a read that failed: keep working under what we already have. */
    @Test
    fun `nothing in the registry keeps the id in use`() {
        assertEquals("my-whoop", ActiveDeviceResolution.resolve(null, inUse = "my-whoop"))
    }

    /**
     * An id of spaces is not an id. Passing it on would blank the process handle, whose own getter reads
     * a blank value as "not resolved yet" and would fall back to the legacy id on the next read.
     */
    @Test
    fun `a blank id is not an id`() {
        assertEquals("whoop-ABC", ActiveDeviceResolution.resolve("", inUse = "whoop-ABC"))
        assertEquals("whoop-ABC", ActiveDeviceResolution.resolve("   ", inUse = "whoop-ABC"))
    }

    /** Surrounding whitespace is noise, not part of the id. */
    @Test
    fun `an id is taken without its surrounding spaces`() {
        assertEquals("whoop-ABC", ActiveDeviceResolution.resolve("  whoop-ABC  ", inUse = "my-whoop"))
    }

    /** Asking twice must answer the same; the callers are allowed to be idempotent. */
    @Test
    fun `resolving what is already in use changes nothing`() {
        assertEquals("whoop-ABC", ActiveDeviceResolution.resolve("whoop-ABC", inUse = "whoop-ABC"))
    }
}
