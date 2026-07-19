import Foundation

// OuraWear: infer whether the Oura ring is on a finger, on the charger, or idle — a live wear/charge
// indicator for the UI ("On wrist" / "Off wrist").
//
// The ring emits no dedicated "worn" event in NOOP's captures: open_health documents an `aohr_event`
// (0x86) that "appears when worn", but that decoder is confirmed by code, not data (ported from
// libringeventparser.so) and has NEVER appeared in a capture (0 records). So wear is inferred from signals
// that ARE present and validated by real data:
//   - a LIVE-HR push (0x2F) exists only while the ring measures on a finger -> WORN;
//   - a live-HR stream that goes silent while we keep re-engaging it -> the ring came off (there is no
//     "removed" event) -> NOT WORN;
//   - the ring's literal "chg. detected" / "chg. stopped" STATE (0x45/0x53) strings -> CHARGING.
//
// Platform-pure, value types + one tiny live accumulator. No CoreBluetooth, no clock (the caller owns the
// watchdog timing). Builds/tests on Linux.

/// The ring's wear / charge state for a live indicator.
public enum OuraWearState: String, Sendable, Codable, CaseIterable {
    case worn        // a live-HR beat streamed since the last charge/removal -> on a finger
    case charging    // between chg.detected and chg.stopped -> on the charger, not worn
    case off         // came off the charger, or the finger (live-HR went silent) -> not worn, no charger
    case unknown     // no evidence yet this session
}

public enum OuraWear {

    // MARK: - STATE-string semantics (clean-room: the ring's own words)

    /// True when a STATE (0x45/0x53) string reports the charger being CONNECTED (observed: "chg. detected").
    /// Matched on the decoded text, the honest signal — the ring literally says it — never a guessed code
    /// (the numeric state codes are ambiguous: e.g. code 5 appears as both "hr enable" and "motion det").
    public static func isChargerStart(_ s: OuraState) -> Bool {
        let t = (s.text ?? "").lowercased()
        return (t.contains("chg") || t.contains("charg")) && (t.contains("detect") || t.contains("start"))
    }

    /// True when a STATE string reports the charger being DISCONNECTED (observed: "chg. stopped").
    public static func isChargerStop(_ s: OuraState) -> Bool {
        let t = (s.text ?? "").lowercased()
        return (t.contains("chg") || t.contains("charg"))
            && (t.contains("stop") || t.contains("end") || t.contains("done") || t.contains("remov"))
    }
}

/// A tiny LIVE state machine for a wear/charge indicator. Feed it STATE events, live-HR pulses, and a
/// pulse-silence timeout as they happen in real time; read `current`. Live semantics only: latest evidence
/// wins. A live-HR beat means WORN (a finger); a charge string means CHARGING/OFF; a silent stream past the
/// caller's grace window means the ring came off. Never feed it a banked/history IBI — that can be a
/// past-night re-serve and would falsely read worn.
public final class OuraWearTracker {
    public private(set) var current: OuraWearState = .unknown

    public init() {}

    /// A decoded STATE (0x45/0x53) event.
    public func note(state: OuraState) {
        if OuraWear.isChargerStart(state) { current = .charging }
        else if OuraWear.isChargerStop(state) { current = .off }
    }

    /// A LIVE heart-rate beat was streamed (the 0x2F live-HR push) — that stream exists only while the ring
    /// is measuring on a finger, so the ring is WORN. Do NOT call this for a banked/history IBI: a history
    /// re-serve can carry beats from a PAST night and would falsely flip the badge to worn while the ring
    /// is actually on the charger. Live push only.
    public func notePulse() { current = .worn }

    /// No live beat has arrived for longer than expected while HR was streaming — the ring came off the
    /// finger (the ring emits no "removed" event; a stopped live-HR stream is the only signal). Downgrades
    /// `.worn` -> `.off` only; never overrides `.charging` (the charger STATE is authoritative) or a state
    /// that was already not-worn. The caller owns the timing (a wall-clock watchdog); the tracker stays pure.
    public func noteLivePulseTimeout() {
        if current == .worn { current = .off }
    }

    /// Reset to `.unknown` (a fresh connection / session).
    public func reset() { current = .unknown }
}
