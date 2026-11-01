package com.noop.ble

/**
 * Detects a strap that ADVERTISES but never ANSWERS connection requests: the scan finds it
 * immediately (often at strong RSSI), `connectGatt` is issued, and the stack gives up ~30s later
 * with status 147 (0x93, the Android 14+ fine-grained code for a connection-establishment
 * timeout) without the link ever reaching STATE_CONNECTED. Seen in the field on a WHOOP 5/MG
 * whose BLE firmware wedged after a spontaneous reboot + RTC corruption: the band kept
 * advertising while refusing every connection, and NOOP retried silently forever — the user saw
 * an endless "Searching…" with no explanation and no way to know the fix is on the strap/phone
 * side (charge-kick the strap, toggle Bluetooth, restart the phone), not a pairing problem.
 *
 * A SINGLE establishment timeout is normal at the edge of range (the connect request can simply
 * be lost), so warning on one would false-alarm healthy setups. We require CONSECUTIVE
 * establishment timeouts with nothing in between: any failed connect with a DIFFERENT status
 * breaks the streak (a different failure means the strap is at least answering), and the caller
 * resets on STATE_CONNECTED / a user teardown. At [warnThreshold] the caller surfaces the
 * recovery guidance; like the #78 pairing hint, the signal repeats on every over-threshold
 * timeout so the caller can re-assert the (idempotent) hint after the UI cleared it.
 *
 * This is an ANDROID-ONLY detector: status 147 is an Android (14+) GATT stack code with no
 * CoreBluetooth analogue — iOS surfaces establishment failures through `didFailToConnect`, which
 * already has its own backoff + guidance (#414), so there is no Swift twin to keep in parity.
 *
 * Pure value type — unit-testable without a GATT seam, same shape as [EmptySyncTracker].
 */
class EstablishTimeoutTracker(
    /** Consecutive establishment timeouts before the guidance shows. 2 (not 1): one lost connect
     *  request is edge-of-range noise; two 30s timeouts in a row (~a minute of silence, with the
     *  strap advertising the whole time) is the wedged-radio signature. */
    private val warnThreshold: Int = 2,
) {
    /** Consecutive failed connects that were establishment timeouts (status 147). */
    var consecutiveTimeouts = 0
        private set

    /**
     * Record a FAILED connect attempt (the link never reached STATE_CONNECTED and the drop was
     * involuntary). [establishTimedOut] = the stack reported a connection-establishment timeout
     * (status 147). Returns true once the streak is SUSTAINED (>= [warnThreshold]) — the caller
     * surfaces/re-asserts the recovery guidance then. Any other failure status breaks the streak.
     */
    fun recordFailedConnect(establishTimedOut: Boolean): Boolean {
        if (!establishTimedOut) {
            consecutiveTimeouts = 0
            return false
        }
        consecutiveTimeouts += 1
        return consecutiveTimeouts >= warnThreshold
    }

    /** Clear the streak: the link established (the strap answered), or the user tore down / released
     *  the strap. The next suspicion must accumulate afresh. */
    fun reset() {
        consecutiveTimeouts = 0
    }
}
