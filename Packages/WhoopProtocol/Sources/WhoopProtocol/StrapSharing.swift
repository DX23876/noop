import Foundation

/// What "share my heart rate from the strap" means on the wire, and what it must NOT mean.
///
/// ## Why this file exists
///
/// The switch moves TWO strap settings that were treated as one:
///
/// - `whoop_live_hr_in_adv_ind_pkt`, the ADVERTISING flag — the strap writes a fresh heart rate into its
///   advertisement about once a second, for anyone in range, with no connection at all. This is the one
///   that costs battery around the clock, and the only one a wearer means by "sharing".
/// - `TOGGLE_GENERIC_HR_PROFILE`(14), the standard heart-rate SERVICE (0x180D/0x2A37) — the channel a
///   CONNECTED device reads. NOOP itself lives on it: live heart rate, R-R intervals, and the liveness
///   watchdog that keeps the link from being torn down all ride it.
///
/// Until 2026-11-15 both directions wrote both settings. Switching sharing off therefore also switched off
/// the service the app itself depends on, which on a strap that had it on by default would take away the
/// wearer's live heart rate and the link's only sign of life as collateral for a setting they had never
/// knowingly enabled.
///
/// So the two directions are deliberately NOT symmetric, and that asymmetry is the safety:
///
/// - ON may be generous. The wearer asked for it in that moment, the service is what a working strap has
///   on anyway, and the advertising flag plausibly needs it (unproven, see below).
/// - OFF must be frugal. It touches the advertising flag and nothing else, so stopping the broadcast can
///   never cost somebody their live heart rate.
///
/// The service keeps its own reversal path in the Test Centre, separate from sharing: what this app can
/// switch on, it must be able to switch off (the BLE safety contract's reversibility test), and after the
/// split the sharing switch is no longer that path.
///
/// ## What is NOT established
///
/// Whether the advertising flag does anything with the service off. It is a hardware question and it only
/// bears on the ON direction; the OFF direction is correct either way, because clearing the flag cannot
/// start anything.
///
/// Pure: no CoreBluetooth, no I/O, no preferences. Kotlin twin is `com.noop.protocol.StrapSharing` —
/// keep them byte-identical.
public enum StrapSharing {

    // MARK: - What a wish writes

    /// Which of the two strap settings one direction of the switch may write.
    ///
    /// `writesService` false does NOT mean "write the service off". It means this direction does not touch
    /// the service at all, which is the whole point of the split.
    public struct Plan: Equatable, Sendable {
        /// Send `TOGGLE_GENERIC_HR_PROFILE`(14) with the requested state.
        public let writesService: Bool
        /// Write `whoop_live_hr_in_adv_ind_pkt` to the requested state.
        public let writesAdvertising: Bool

        public init(writesService: Bool, writesAdvertising: Bool) {
            self.writesService = writesService
            self.writesAdvertising = writesAdvertising
        }
    }

    /// The writes one direction of the sharing switch is allowed to make.
    ///
    /// Asked at the call site rather than inlined there, so the asymmetry is one fact in one place that a
    /// test can pin, instead of an `if on` a later edit can quietly make symmetric again.
    public static func plan(on: Bool) -> Plan {
        Plan(writesService: on, writesAdvertising: true)
    }

    // MARK: - A wish that could not be sent

    /// Whether a remembered OFF wish belongs to the strap that is connected now.
    ///
    /// The wish is stored as the device id it was made for, because a wearer with two straps who switches
    /// sharing off on one of them must not have it cleared on the other the next time that one connects.
    /// Nil on either side means "cannot attribute it", and an unattributable write is never sent.
    public static func pendingApplies(pendingDeviceId: String?, activeDeviceId: String?) -> Bool {
        guard let pending = pendingDeviceId, !pending.isEmpty else { return false }
        guard let active = activeDeviceId, !active.isEmpty else { return false }
        return pending == active
    }

    // MARK: - What a reader is told

    /// What is known about sharing, from the two values a platform stores: the state the strap last
    /// claimed and when it was read.
    ///
    /// Here rather than at each caller, because the two platforms decided it differently the first time —
    /// Apple from the stored flag being absent, Android from the timestamp being zero — and the same pair
    /// of values could then print two different header lines on two phones. Both halves are required:
    /// a state with no reading time, or a time with no state, is a half-written record and reads as
    /// UNKNOWN rather than as one of the two answers.
    public static func lastKnownState(storedOn: Bool?, readAtEpochSeconds: Double) -> Bool? {
        guard readAtEpochSeconds > 0, let on = storedOn else { return nil }
        return on
    }

    /// The strap-log header line for what is known about sharing, in the padded shape of its neighbours
    /// ("Model:", "Firmware:", "Last sync:").
    ///
    /// Three states, never two: a strap that has never been asked is UNKNOWN, not off. Reporting an
    /// unasked strap as "off" is exactly the readout that cost two hours of reading raw firmware lines to
    /// answer one wearer's battery report, and it is the state most likely to be the broken one — the app
    /// believing sharing is off is how a strap gets stranded in the first place.
    ///
    /// [age] is the caller's already-rendered "5m ago"; nil when nothing was ever heard.
    public static func headerLine(stateOn: Bool?, age: String?) -> String {
        let label = "Sharing:     "
        guard let on = stateOn else {
            return label + "unknown (never read from this strap)"
        }
        let when = age.map { " · read \($0)" } ?? ""
        return label + (on
            ? "ON — the strap broadcasts its heart rate continuously\(when)"
            : "off\(when)")
    }
}
