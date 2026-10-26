package com.noop.ble

import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.LooperMode

/** Android retains the original registration when a duplicate start reports ALREADY_STARTED. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE, application = Application::class,
    shadows = [ScanFailureRecoveryTest.RegisteredScanner::class])
@LooperMode(LooperMode.Mode.PAUSED)
class ScanFailureRecoveryTest {
    @Before
    fun reset() {
        RegisteredScanner.callback = null
        RegisteredScanner.duplicateStarts = 0
        RegisteredScanner.denyAfterRegistration = false
        BluetoothAdapter.getDefaultAdapter().enable()
    }

    @Test
    fun duplicateFailureDoesNotLeaveEveryLaterWizardScanAlreadyStarted() {
        val client = WhoopBleClient(RuntimeEnvironment.getApplication())
        client.scanForWhoops(WhoopModel.WHOOP4)
        val first = RegisteredScanner.callback
        assertNotNull("the wizard registered its scanner", first)
        assertTrue(client.state.value.scanning)

        // A duplicate attempt fails without cancelling the original Android registration. The client marks its
        // UI scan inactive, but dismissing the wizard must still unregister the native callback.
        first!!.onScanFailed(ScanCallback.SCAN_FAILED_ALREADY_STARTED)
        assertFalse(client.state.value.scanning)
        assertTrue("the Live page must show the failure instead of its old searching note",
            client.state.value.statusNote?.contains("ALREADY_STARTED") == true)
        client.stopWhoopScan()
        assertNull("a failed scan still needs native cleanup", RegisteredScanner.callback)

        client.scanForWhoops(WhoopModel.WHOOP4)
        assertNotNull(RegisteredScanner.callback)
        assertNull("a new wizard scan clears the previous failure note", client.state.value.statusNote)
        assertEquals("the next Rescan must not hit the old registration", 0, RegisteredScanner.duplicateStarts)
        client.stopWhoopScan()
    }

    @Test
    fun permissionFailureAfterRegistrationIsCleanedBeforeRetry() {
        val client = WhoopBleClient(RuntimeEnvironment.getApplication())
        RegisteredScanner.denyAfterRegistration = true
        client.scanForWhoops(WhoopModel.WHOOP4)
        assertNotNull("the framework may register before its remote permission check fails",
            RegisteredScanner.callback)

        client.scanForWhoops(WhoopModel.WHOOP4)
        assertEquals("retry after permission grant must remove the abandoned callback", 0,
            RegisteredScanner.duplicateStarts)
        assertNotNull(RegisteredScanner.callback)
        client.stopWhoopScan()
    }

    @Implements(BluetoothLeScanner::class)
    class RegisteredScanner {
        @Implementation
        fun startScan(filters: List<ScanFilter>, settings: ScanSettings, next: ScanCallback) {
            if (callback != null) {
                duplicateStarts++
                next.onScanFailed(ScanCallback.SCAN_FAILED_ALREADY_STARTED)
            } else {
                callback = next
                if (denyAfterRegistration) {
                    denyAfterRegistration = false
                    throw SecurityException("scan permission denied after callback registration")
                }
            }
        }

        @Implementation
        fun stopScan(current: ScanCallback) {
            if (callback === current) callback = null
        }

        companion object {
            var callback: ScanCallback? = null
            var duplicateStarts = 0
            var denyAfterRegistration = false
        }
    }
}
