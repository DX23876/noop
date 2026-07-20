package com.noop.oura

// OuraWear: infer whether the Oura ring is on a finger, on the charger, or idle — a live wear/charge
// indicator for the UI ("On wrist" / "Off wrist").
//
// Kotlin twin of Packages/OuraProtocol/Sources/OuraProtocol/OuraWear.swift. The ring emits no dedicated
// "worn" event in NOOP's captures (the documented aohr_event 0x86 has NEVER appeared — 0 records), so
// wear is inferred from signals that ARE present and validated by real data:
//   - a LIVE-HR push (0x2F) exists only while the ring measures on a finger -> WORN;
//   - a live-HR stream that goes silent while we keep re-engaging it -> the ring came off -> NOT WORN;
//   - the ring's literal "chg. detected" / "chg. stopped" STATE (0x45/0x53) strings -> CHARGING.
//
// Platform-pure (no android.*), value types + one tiny live accumulator. No clock (the caller owns the
// watchdog timing). Runs in JVM unit tests — see OuraWearTest.

/** The ring's wear / charge state for a live indicator. */
enum class OuraWearState {
    WORN,       // a live-HR beat streamed since the last charge/removal -> on a finger
    CHARGING,   // between chg.detected and chg.stopped -> on the charger, not worn
    OFF,        // came off the charger, or the finger (live-HR went silent) -> not worn, no charger
    UNKNOWN,    // no evidence yet this session
}

object OuraWear {

    // MARK: - STATE-string semantics (clean-room: the ring's own words)

    /** True when a STATE (0x45/0x53) string reports the charger being CONNECTED (observed: "chg.
     *  detected"). Matched on the decoded text — the honest signal, the ring literally says it — never a
     *  guessed numeric code (the state codes are ambiguous: code 5 appears as both "hr enable" and
     *  "motion det"). Twin of OuraWear.isChargerStart (Swift). */
    fun isChargerStart(state: OuraState): Boolean {
        val t = (state.text ?: "").lowercase()
        return (t.contains("chg") || t.contains("charg")) && (t.contains("detect") || t.contains("start"))
    }

    /** True when a STATE string reports the charger being DISCONNECTED (observed: "chg. stopped"). */
    fun isChargerStop(state: OuraState): Boolean {
        val t = (state.text ?: "").lowercase()
        return (t.contains("chg") || t.contains("charg")) &&
            (t.contains("stop") || t.contains("end") || t.contains("done") || t.contains("remov"))
    }
}

/**
 * A tiny LIVE state machine for a wear/charge indicator. Feed it STATE events, live-HR pulses, and a
 * pulse-silence timeout as they happen in real time; read [current]. Live semantics only: latest
 * evidence wins. A live-HR beat means WORN; a charge string means CHARGING/OFF; a silent stream past
 * the caller's grace window means the ring came off. Never feed it a banked/history IBI — that can be a
 * past-night re-serve and would falsely read worn. Twin of OuraWearTracker (Swift).
 */
class OuraWearTracker {
    var current: OuraWearState = OuraWearState.UNKNOWN
        private set

    /** A decoded STATE (0x45/0x53) event. */
    fun note(state: OuraState) {
        when {
            OuraWear.isChargerStart(state) -> current = OuraWearState.CHARGING
            OuraWear.isChargerStop(state) -> current = OuraWearState.OFF
        }
    }

    /** A LIVE heart-rate beat was streamed (the 0x2F live-HR push) — that stream exists only while the
     *  ring is measuring on a finger, so the ring is WORN. Do NOT call this for a banked/history IBI: a
     *  history re-serve can carry beats from a PAST night and would falsely flip the badge to worn while
     *  the ring is actually on the charger. Live push only. */
    fun notePulse() { current = OuraWearState.WORN }

    /** No live beat has arrived for longer than expected while HR was streaming — the ring came off the
     *  finger (there is no "removed" event; a stopped live-HR stream is the only signal). Downgrades
     *  WORN -> OFF only; never overrides CHARGING (the charger STATE is authoritative) or a state that
     *  was already not-worn. The caller owns the timing (a wall-clock watchdog); this stays pure. */
    fun noteLivePulseTimeout() {
        if (current == OuraWearState.WORN) current = OuraWearState.OFF
    }

    /** Reset to UNKNOWN (a fresh connection / session). */
    fun reset() { current = OuraWearState.UNKNOWN }
}
