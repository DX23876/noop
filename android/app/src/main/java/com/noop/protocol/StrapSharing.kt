package com.noop.protocol

/**
 * What "share my heart rate from the strap" means on the wire, and what it must NOT mean.
 *
 * ## Why this file exists
 *
 * The switch moves TWO strap settings that were treated as one:
 *
 * - `whoop_live_hr_in_adv_ind_pkt`, the ADVERTISING flag — the strap writes a fresh heart rate into its
 *   advertisement about once a second, for anyone in range, with no connection at all. This is the one
 *   that costs battery around the clock, and the only one a wearer means by "sharing".
 * - `TOGGLE_GENERIC_HR_PROFILE`(14), the standard heart-rate SERVICE (0x180D/0x2A37) — the channel a
 *   CONNECTED device reads. NOOP itself lives on it: live heart rate, R-R intervals, and the liveness
 *   watchdog that keeps the link from being torn down all ride it.
 *
 * Until 2026-11-15 both directions wrote both settings. Switching sharing off therefore also switched off
 * the service the app itself depends on, which on a strap that had it on by default would take away the
 * wearer's live heart rate and the link's only sign of life as collateral for a setting they had never
 * knowingly enabled.
 *
 * So the two directions are deliberately NOT symmetric, and that asymmetry is the safety:
 *
 * - ON may be generous. The wearer asked for it in that moment, the service is what a working strap has
 *   on anyway, and the advertising flag plausibly needs it (unproven, see below).
 * - OFF must be frugal. It touches the advertising flag and nothing else, so stopping the broadcast can
 *   never cost somebody their live heart rate.
 *
 * The service keeps its own reversal path in the Test Centre, separate from sharing: what this app can
 * switch on, it must be able to switch off (the BLE safety contract's reversibility test), and after the
 * split the sharing switch is no longer that path.
 *
 * ## What is NOT established
 *
 * Whether the advertising flag does anything with the service off. It is a hardware question and it only
 * bears on the ON direction; the OFF direction is correct either way, because clearing the flag cannot
 * start anything.
 *
 * Pure: no Android, no I/O, no preferences. Swift twin is `WhoopProtocol.StrapSharing` — keep them
 * byte-identical.
 */
object StrapSharing {

    // region What a wish writes

    /**
     * Which of the two strap settings one direction of the switch may write.
     *
     * [writesService] false does NOT mean "write the service off". It means this direction does not touch
     * the service at all, which is the whole point of the split.
     */
    data class Plan(val writesService: Boolean, val writesAdvertising: Boolean)

    /**
     * The writes one direction of the sharing switch is allowed to make.
     *
     * Asked at the call site rather than inlined there, so the asymmetry is one fact in one place that a
     * test can pin, instead of an `if (on)` a later edit can quietly make symmetric again.
     */
    @JvmStatic
    fun plan(on: Boolean): Plan = Plan(writesService = on, writesAdvertising = true)

    // endregion

    // region A wish that could not be sent

    /**
     * Whether a remembered OFF wish belongs to the strap that is connected now.
     *
     * The wish is stored as the device id it was made for, because a wearer with two straps who switches
     * sharing off on one of them must not have it cleared on the other the next time that one connects.
     * Null on either side means "cannot attribute it", and an unattributable write is never sent.
     */
    @JvmStatic
    fun pendingApplies(pendingDeviceId: String?, activeDeviceId: String?): Boolean {
        if (pendingDeviceId.isNullOrEmpty()) return false
        if (activeDeviceId.isNullOrEmpty()) return false
        return pendingDeviceId == activeDeviceId
    }

    // endregion

    // region What a reader is told

    /**
     * The strap-log header line for what is known about sharing, in the padded shape of its neighbours
     * ("Model:", "Firmware:", "Last sync:").
     *
     * Three states, never two: a strap that has never been asked is UNKNOWN, not off. Reporting an
     * unasked strap as "off" is exactly the readout that cost two hours of reading raw firmware lines to
     * answer one wearer's battery report, and it is the state most likely to be the broken one — the app
     * believing sharing is off is how a strap gets stranded in the first place.
     *
     * [age] is the caller's already-rendered "5m ago"; null when nothing was ever heard.
     */
    @JvmStatic
    fun headerLine(stateOn: Boolean?, age: String?): String {
        val label = "Sharing:     "
        if (stateOn == null) return label + "unknown (never read from this strap)"
        val whenRead = if (age.isNullOrEmpty()) "" else " · read $age"
        return label + if (stateOn) {
            "ON — the strap broadcasts its heart rate continuously$whenRead"
        } else {
            "off$whenRead"
        }
    }

    // endregion
}
