package com.noop.ble

/**
 * Mirror of the Swift `EmptySyncTracker` (Strand/BLE/BLEManager.swift).
 *
 * Decides when a completed sync that handed over only the strap's console/diagnostic output (no sensor
 * records) is sustained enough to warn that the strap's clock has lost sync and it isn't banking to flash
 * (#77 / #91 / #120). A SINGLE empty cycle is common on a perfectly healthy strap — the strap can hand
 * back a console-only window, especially under heavy live-HR polling — so warning on one cycle
 * false-alarms users whose clock is fine (#126). We require CONSECUTIVE empty cycles; any cycle that banks
 * real sensor records clears the streak. Pure → unit-testable without a BLE seam.
 */
class EmptySyncTracker(
    /**
     * Consecutive console-only completed syncs before the clock-lost banner shows. 3 (not 1): a genuinely
     * un-banking strap is console-only on EVERY cycle, so 3 is reached within minutes, while a transient
     * empty cycle amid healthy ones never accumulates.
     */
    private val threshold: Int = 3,
) {
    var consecutiveEmptySyncs = 0
        private set

    /**
     * Record a COMPLETED (HISTORY_COMPLETE) offload. [bankedSensorRecords] = the strap handed over real
     * sensor records this cycle (decoded, or undecodable-but-archived — either way the clock is banking).
     * [consoleOnly] = it handed over only diagnostic frames and no sensor records. Returns true only once
     * emptiness is SUSTAINED (>= [threshold] consecutive console-only cycles) — the caller shows the
     * "clock has lost sync" banner only then. Any banking cycle, or a caught-up cycle with nothing to
     * offload, clears the streak.
     *
     * [strapOffWrist] = the strap's last wrist event on this link was WRIST_OFF when the offload began. An off-wrist
     * strap handing over nothing says nothing about its clock, so such a cycle neither counts toward the streak nor
     * clears it, and it returns the streak it leaves standing: a banner on-wrist cycles already raised stays up.
     * Adapted from ayiskakov/noop (W06-109, W06-116); mirrors Swift.
     */
    fun recordCompletedSync(bankedSensorRecords: Boolean, consoleOnly: Boolean, strapOffWrist: Boolean = false): Boolean {
        if (!consoleOnly || bankedSensorRecords) {
            consecutiveEmptySyncs = 0
            return false
        }
        if (strapOffWrist) return consecutiveEmptySyncs >= threshold
        consecutiveEmptySyncs += 1
        return consecutiveEmptySyncs >= threshold
    }
}
