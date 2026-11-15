package com.noop.protocol

/**
 * `TOGGLE_GENERIC_HR_PROFILE` (14) — the strap's own switch for the STANDARD BLE heart-rate service
 * (0x180D / 0x2A37), and the one write this app may form for it.
 *
 * ## Why this gate exists
 *
 * A 2026-11-15 field log (WHOOP 5.0, firmware 50.41.1.0) delivered NOTHING on 0x2A37 for a whole day
 * after the wearer switched to it: 41 successful subscriptions, ten renewals after 90 s of silence each,
 * and not one `HR notify` line in 28,784 lines. The strap said why itself, on the one reboot in that log:
 *
 * ```
 * BLE: Previously Saved HRS State OFF
 * ```
 *
 * A strap where the live heart rate works logs `Previously Saved HRS State ON` in the same place. So the
 * heart-rate service is a PERSISTED strap setting, it was off on that strap, and nothing in NOOP could
 * read or move it.
 *
 * Opcode 14 is the switch for it. NOOP already sends it on a WHOOP 4.0 (`WhoopBleClient.setBroadcastHr`);
 * on a 5/MG the same method took the device-config route instead, and 14 was never in the 5/MG framing
 * allowlist, so it was dropped with `no WHOOP 5/MG framing for this command yet`.
 *
 * ## Why it is safe to offer
 *
 * It is the reversible shape, which is the test the BLE safety contract applies: [body] has an off form,
 * and the strap announces the RESULTING state with its own events ([ENABLED_EVENT] 24 / [DISABLED_EVENT]
 * 25), with the boot line above as a second, independent witness. Nothing is written into a table whose
 * previous value was never read, and no data is erased either way.
 *
 * **The vendor app is not an alternative.** It pulls a firmware update as soon as it connects and locks
 * the strap out of NOOP, so for a strap whose service is off this command is the only route back, not a
 * convenience.
 *
 * ## What is NOT established
 *
 * Whether a 5/MG serves opcode 14 at all, and whether it takes the same one-byte body the 4.0 takes. Both
 * are hardware checks. Even on the 4.0 the evidence is an acknowledgement, not an observed effect, so the
 * caller must report the EVENT, never the command response, as the outcome.
 *
 * Pure: no Bluetooth, no I/O, no preferences. The app layer supplies the opt-in. Swift twin is
 * `GenericHrProfileGate` in WhoopProtocol — keep them byte-identical.
 */
object GenericHrProfileGate {

    /** `TOGGLE_GENERIC_HR_PROFILE` (14 / 0x0E) — the only opcode this gate admits. */
    const val TOGGLE_GENERIC_HR_PROFILE_CMD = 14

    /**
     * `SET_DEVICE_CONFIG_VALUE` (119) — the OTHER route the same switch uses on a 5/MG. Named here for one
     * reason: so [admitsSend] can be proved to refuse it. The two are different settings and each keeps
     * its own clause.
     */
    const val SET_DEVICE_CONFIG_VALUE_CMD = 119

    /** Event 24: the strap says its heart-rate profile is now ON. */
    const val ENABLED_EVENT = "BLE_HR_PROFILE_ENABLED"

    /** Event 25: the strap says its heart-rate profile is now OFF. */
    const val DISABLED_EVENT = "BLE_HR_PROFILE_DISABLED"

    /**
     * The state an event name reports, or null when the name is neither of the two. Prefix-matched because
     * the decoder appends the raw number to an event name.
     *
     * This is the NAME's meaning only. A caller that states the CURRENT service state must use
     * [liveStateFromEvent] instead, or it will report a banked event as the present.
     */
    fun stateFromEvent(event: String): Boolean? = when {
        event.startsWith(ENABLED_EVENT) -> true
        event.startsWith(DISABLED_EVENT) -> false
        else -> null
    }

    /**
     * The state an event may be reported as RIGHT NOW: [stateFromEvent], except null for an event replayed
     * out of the strap's banked event log during an offload.
     *
     * A strap banks these events like any other, so an offload hands over an old one. Reporting that as the
     * present state prints the OPPOSITE of the truth for a service that has been switched since — in the
     * one always-on line someone reads when diagnosing a silent 0x2A37. The same discriminator the charging
     * flag and the strap-driven-alarm event already consult ([shouldApplyChargingFromBatteryEvent],
     * [smartAlarmFiredForEvent] in WhoopBleClient), as a rule rather than an inline `if`, so both platforms
     * answer alike.
     */
    fun liveStateFromEvent(event: String, replayedOffload: Boolean): Boolean? =
        if (replayedOffload) null else stateFromEvent(event)

    /**
     * The one-byte request body: `01` on, `00` off. Same form the WHOOP 4.0 takes; whether a 5/MG takes it
     * is the hardware check this gate exists to make possible.
     */
    fun body(on: Boolean): ByteArray = byteArrayOf(if (on) 1.toByte() else 0.toByte())

    /**
     * The state a well-formed body asks for, or null when the payload is not one of the two.
     *
     * Deliberately exact rather than "first byte wins": a longer or shorter body is not a request this app
     * formed, and admitting it would widen the gate to whatever a future caller happens to pass.
     */
    fun requestedState(payload: ByteArray): Boolean? {
        if (payload.size != 1) return null
        return when (payload[0]) {
            1.toByte() -> true
            0.toByte() -> false
            else -> null
        }
    }

    /**
     * **The send allowlist.** True only for `TOGGLE_GENERIC_HR_PROFILE(14)` carrying exactly `01` or `00`,
     * while the Broadcast-HR opt-in is on.
     *
     * Every other opcode is false, explicitly including `SET_DEVICE_CONFIG_VALUE(119)`, which keeps its own
     * key-aware clause in [DeviceConfigWriteGate] and must never be reachable from here.
     *
     * The OFF write is admitted UNCONDITIONALLY, and that is not a loophole but the whole undo path. The
     * opt-in is bound straight to the Settings switch, so it is already `false` by the time
     * `setBroadcastHr(false)` runs: gating the off direction on it refuses the one write that stops the
     * strap serving its heart rate, leaving the switch off, the service on, and no way to clear it. Both
     * sibling gates record the same lesson from having shipped it — [DeviceConfigWriteGate.admitsSend]
     * (#1061, "gating the OFF write on it made the toggle-off path DEAD") and the #174 R22 disable clause.
     * Admitting it costs nothing: `00` cannot enable anything, and the strap's own event reports the result.
     *
     * TWO opt-ins may authorise the ON, because two deliberate switches legitimately want this one command:
     * sharing, which needs the service as its prerequisite, and the service's own control, which exists
     * because [StrapSharing] stopped the OFF direction of sharing from touching the service and what this
     * app can switch on it must be able to switch off. Each is bound to a visible switch, so neither rides
     * in on consent given for something else. [serviceOptIn] defaults to false and so fails CLOSED: a
     * caller that forgets it gets a refusal, logged by the call site, never a silent widening.
     */
    fun admitsSend(
        opcode: Int,
        payload: ByteArray,
        broadcastHrOptIn: Boolean,
        serviceOptIn: Boolean = false,
    ): Boolean {
        if (opcode != TOGGLE_GENERIC_HR_PROFILE_CMD) return false
        val on = requestedState(payload) ?: return false
        return if (on) (broadcastHrOptIn || serviceOptIn) else true
    }
}
