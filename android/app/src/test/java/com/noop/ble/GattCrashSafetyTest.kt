package com.noop.ble

import android.os.DeadObjectException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Crash-safety + stale-connection policy for #314 (Pixel 7, Bluetooth turned off mid-link).
 *
 * Two coupled Android-only defects were fixed in [WhoopBleClient]:
 *   1. STALE-CONNECTED — turning the OS Bluetooth radio off never tore down the orphaned GATT, so the
 *      UI kept showing live HR/buzz/sync that wasn't real. A new ACTION_STATE_CHANGED receiver in
 *      WhoopConnectionService now calls [WhoopBleClient.onBluetoothRadioOff], which runs the full
 *      teardown and publishes connected = false.
 *   2. CRASH — the raw `writeCharacteristic` (and the other GATT calls) had no try/catch, so once the
 *      binder died they threw `DeadObjectException` (an unchecked RuntimeException) and crashed the app
 *      on the next buzz/write. Every raw GATT call is now wrapped in `safeGatt`, whose catch policy is
 *      single-sourced in [WhoopBleClient.shouldTeardownOnGattThrow] and which routes into the existing
 *      disconnect/teardown path.
 *
 * INFRA NOTE: the full instance-level behaviour (a real `drainWriteQueue` against a stubbed GATT whose
 * `writeCharacteristic` throws → `writeInFlight` reset, queue drained, `state.connected == false`,
 * scheduled retries cancelled, and a subsequent buzz hitting the not-connected guard) cannot be
 * exercised here: [WhoopBleClient]'s constructor builds a `Handler(Looper.getMainLooper())` and calls
 * `context.getSystemService(...)`, both of which throw under the unit harness's stub `android.jar`
 * (the project ships NO Robolectric — see app/build.gradle.kts: only junit + kotlinx-coroutines-test +
 * real org.json/kxml2). The production code is structured for that test the moment a Robolectric/
 * instrumented seam exists: the new `gattOpsFactory` constructor parameter lets a test inject a stub
 * [GattOps] whose `writeCharacteristicCompat` throws `DeadObjectException`. These tests pin the pure
 * decision logic that the full behaviour is built on, matching the existing BLE-test pattern
 * ([SyncNowGateTest], which likewise tests pure predicates rather than the live GATT stack).
 */
class GattCrashSafetyTest {

    // --- Catch policy: every GATT throw must route to teardown (never crash) -------------------------

    @Test
    fun deadObjectException_triggersTeardown() {
        // THE #314 crash: the binder died, writeCharacteristic threw DeadObjectException. Must tear down.
        assertTrue(WhoopBleClient.shouldTeardownOnGattThrow(DeadObjectException()))
    }

    @Test
    fun illegalStateException_triggersTeardown() {
        // Adapter/stack in a bad state once Bluetooth is going down.
        assertTrue(WhoopBleClient.shouldTeardownOnGattThrow(IllegalStateException("adapter off")))
    }

    @Test
    fun securityException_triggersTeardown() {
        // BLUETOOTH_CONNECT permission revoked mid-link.
        assertTrue(WhoopBleClient.shouldTeardownOnGattThrow(SecurityException("permission revoked")))
    }

    @Test
    fun anyOtherThrowable_triggersTeardown() {
        // There is no recoverable GATT throw: continuing to drive a throwing binder is never correct,
        // so the safe response is always teardown rather than crash.
        assertTrue(WhoopBleClient.shouldTeardownOnGattThrow(RuntimeException("unexpected")))
        assertTrue(WhoopBleClient.shouldTeardownOnGattThrow(NullPointerException()))
    }

    // --- Stale-connection: teardown publishes a genuinely disconnected LiveState --------------------

    @Test
    fun teardown_flipsConnectedFalse_andClearsLiveBiometrics() {
        // BEFORE: a fully-live link mid-offload, showing real HR/RR/battery/charging — exactly the
        // stale-connected state the #314 reporter saw "continuing" after Bluetooth was switched off.
        val live = LiveState(
            connected = true,
            bonded = true,
            encryptedBond = true,
            heartRate = 72,
            rr = listOf(820, 815),
            rrRecent = listOf(820, 815, 810),
            batteryPct = 64.0,
            charging = true,
            strapFirmware = "41.17.6.0",
            historyLayoutVersion = 25,
            backfilling = true,
            syncChunksThisSession = 12,
        )

        val after = WhoopBleClient.disconnectedLiveState(live)

        // The single most important assertion (the user-visible bug): the UI must read DISCONNECTED.
        assertFalse("link must read disconnected after teardown", after.connected)
        assertFalse(after.bonded)
        assertFalse(after.encryptedBond)
        // Stale biometrics must not outlive the link — no phantom HR/RR after the radio goes off.
        assertNull("heart rate must clear so the UI can't show a stale BPM", after.heartRate)
        assertTrue(after.rr.isEmpty())
        assertTrue(after.rrRecent.isEmpty())
        // The "Syncing strap history…" pill must clear too (a dropped link mid-offload can't stay stuck).
        assertFalse(after.backfilling)
        assertEquals(0, after.syncChunksThisSession)
        // A stale charging flag must not outlive the link.
        assertNull(after.charging)
        assertNull(after.strapFirmware)
        assertNull(after.historyLayoutVersion)
    }

    @Test
    fun teardown_isIdempotent_onAnAlreadyDisconnectedState() {
        // Calling the teardown transition again (e.g. STATE_TURNING_OFF then STATE_OFF both arrive)
        // must stay disconnected — no flip back to connected.
        val once = WhoopBleClient.disconnectedLiveState(LiveState(connected = true, heartRate = 80))
        val twice = WhoopBleClient.disconnectedLiveState(once)
        assertFalse(twice.connected)
        assertNull(twice.heartRate)
    }

    // --- Not-connected guard: a buzz after the radio is off must never reach a GATT write -----------

    @Test
    fun sendGuard_blocksWriteWhenNotConnected() {
        // After teardown, gatt + cmdCharacteristic are null and state.connected is false. send()'s guard
        // (`gatt == null || ch == null`) is what makes a buzz a no-op instead of reaching the dead write.
        // canRequestSync is the offload twin of that guard and is the pure predicate available here:
        // every kick/sync path is gated on `connected`, so once teardown sets connected = false, no
        // command path fires. (The send() guard itself needs a live instance — see the infra note.)
        val afterTeardown = WhoopBleClient.disconnectedLiveState(LiveState(connected = true, bonded = true))
        assertFalse(
            "no sync/command may fire once the radio-off teardown set connected = false",
            WhoopBleClient.canRequestSync(
                connected = afterTeardown.connected,
                bonded = afterTeardown.bonded,
                backfilling = afterTeardown.backfilling,
            ),
        )
    }
}
