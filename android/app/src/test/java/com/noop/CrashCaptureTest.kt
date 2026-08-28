package com.noop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashCaptureTest {
    @Test
    fun unchangedCrashIsShownUntilAcknowledged() {
        val fingerprint = CrashCapture.fingerprint("stack trace")
        assertTrue(CrashCapture.isPending(fingerprint, null))
        assertTrue(CrashCapture.isPending(fingerprint, "older crash"))
        assertFalse(CrashCapture.isPending(fingerprint, fingerprint))
    }

    @Test
    fun fingerprintIsStableAndDistinguishesNewCrashes() {
        assertEquals(CrashCapture.fingerprint("same"), CrashCapture.fingerprint("same"))
        assertNotEquals(CrashCapture.fingerprint("first"), CrashCapture.fingerprint("second"))
    }

    @Test
    fun crashHeaderIdentifiesBuildAndAndroidDevice() {
        val header = CrashCapture.crashHeader(
            whenText = "Fri Aug 28 18:23:24 GMT+02:00 2026",
            threadName = "DefaultDispatcher-worker-6",
            appVersion = "10.6.1-staging",
            versionCode = 388,
            packageName = "com.noop.whoop.staging",
            androidRelease = "16",
            sdk = 36,
            manufacturer = "Google",
            model = "Pixel 9",
        )
        assertTrue(header.contains("app:    10.6.1-staging (388) · com.noop.whoop.staging"))
        assertTrue(header.contains("os:     Android 16 (API 36)"))
        assertTrue(header.contains("device: Google Pixel 9"))
        assertTrue(header.contains("thread: DefaultDispatcher-worker-6"))
    }
}
