import Foundation

/// `TOGGLE_GENERIC_HR_PROFILE` (14) — the strap's own switch for the STANDARD BLE heart-rate service
/// (0x180D / 0x2A37), and the one write this app may form for it.
///
/// ## Why this gate exists
///
/// A 2026-11-15 field log (WHOOP 5.0, firmware 50.41.1.0) delivered NOTHING on 0x2A37 for a whole day
/// after the wearer switched to it: 41 successful subscriptions, ten renewals after 90 s of silence each,
/// and not one `HR notify` line in 28,784 lines. The strap said why itself, on the one reboot in that log:
///
/// ```
/// BLE: Previously Saved HRS State OFF
/// ```
///
/// A strap where the live heart rate works logs `Previously Saved HRS State ON` in the same place
/// (`backlog/research/ecg-2026-10-08`, a WHOOP MG). So the heart-rate service is a PERSISTED strap
/// setting, it was off on that strap, and nothing in NOOP could read or move it.
///
/// Opcode 14 is the switch for it. NOOP already sends it on a WHOOP 4.0 (`BLEManager.setBroadcastHr`);
/// on a 5/MG the same method took the device-config route instead, and 14 was never in the 5/MG framing
/// allowlist, so it was dropped with `no WHOOP 5/MG framing for this command yet`.
///
/// ## Why it is safe to offer
///
/// It is the reversible shape, which is the test the BLE safety contract applies: `body(on:)` has an off
/// form, and the strap announces the RESULTING state with its own events (`BLE_HR_PROFILE_ENABLED` 24 /
/// `BLE_HR_PROFILE_DISABLED` 25), with the boot line above as a second, independent witness. Nothing is
/// written into a table whose previous value was never read, and no data is erased either way.
///
/// **The vendor app is not an alternative.** It pulls a firmware update as soon as it connects and locks
/// the strap out of NOOP, so for a strap whose service is off this command is the only route back, not a
/// convenience.
///
/// ## What is NOT established
///
/// Whether a 5/MG serves opcode 14 at all, and whether it takes the same one-byte body the 4.0 takes.
/// Both are hardware checks. Even on the 4.0 the evidence is an acknowledgement, not an observed effect —
/// `FrameRouter` logs that response verbatim and says `effect not confirmed` rather than claiming one. So
/// the caller must report the EVENT, never the command response, as the outcome.
///
/// Pure: no CoreBluetooth, no I/O, no preferences. The app layer supplies the opt-in. Kotlin twin is
/// `com.noop.protocol.GenericHrProfileGate` — keep them byte-identical.
public enum GenericHrProfileGate {

    // MARK: - Opcode

    /// `TOGGLE_GENERIC_HR_PROFILE` (14 / 0x0E) — the only opcode this gate admits.
    public static let toggleGenericHrProfileCmd: UInt8 = 14

    /// `SET_DEVICE_CONFIG_VALUE` (119) — the OTHER route the Broadcast-HR switch uses on a 5/MG. Named
    /// here for one reason: so `admitsSend` can be proved to refuse it. The two are different settings and
    /// each keeps its own clause.
    public static let setDeviceConfigValueCmd: UInt8 = 119

    // MARK: - Events (the only outcome worth reporting)

    /// Event 24: the strap says its heart-rate profile is now ON.
    public static let enabledEvent = "BLE_HR_PROFILE_ENABLED"

    /// Event 25: the strap says its heart-rate profile is now OFF.
    public static let disabledEvent = "BLE_HR_PROFILE_DISABLED"

    /// The state an event name reports, or nil when the name is neither of the two. Prefix-matched because
    /// the decoder appends the raw number to an event name.
    public static func stateFromEvent(_ event: String) -> Bool? {
        if event.hasPrefix(enabledEvent) { return true }
        if event.hasPrefix(disabledEvent) { return false }
        return nil
    }

    // MARK: - Body

    /// The one-byte request body: `01` on, `00` off. Same form the WHOOP 4.0 takes; whether a 5/MG takes
    /// it is the hardware check this gate exists to make possible.
    public static func body(on: Bool) -> [UInt8] { [on ? 0x01 : 0x00] }

    /// The state a well-formed body asks for, or nil when the payload is not one of the two.
    ///
    /// Deliberately exact rather than "first byte wins": a longer or shorter body is not a request this
    /// app formed, and admitting it would widen the gate to whatever a future caller happens to pass.
    public static func requestedState(inSendPayload payload: [UInt8]) -> Bool? {
        guard payload.count == 1 else { return nil }
        if payload[0] == 0x01 { return true }
        if payload[0] == 0x00 { return false }
        return nil
    }

    // MARK: - The allowlist predicate

    /// **The send allowlist.** True only for `TOGGLE_GENERIC_HR_PROFILE(14)` carrying exactly `01` or
    /// `00`, while the Broadcast-HR opt-in is on.
    ///
    /// Every other opcode is false, explicitly including `SET_DEVICE_CONFIG_VALUE(119)`, which keeps its
    /// own key-aware clause in `DeviceConfigWriteGate` and must never be reachable from here.
    public static func admitsSend(opcode: UInt8, payload: [UInt8], broadcastHrOptIn: Bool) -> Bool {
        guard broadcastHrOptIn else { return false }
        guard opcode == toggleGenericHrProfileCmd else { return false }
        return requestedState(inSendPayload: payload) != nil
    }
}
