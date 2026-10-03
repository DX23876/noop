#if DEBUG
import Foundation

// MARK: - DEBUG-only sync-indicator harness
//
// A companion to DemoDayHarness for Liquid Today's sync line and the quick-action device row. Neither
// `--demo-seed` nor `--demo-hour` can drive them: they read LiveState (strap connection, battery
// percentage, backfill progress), none of which the synthetic dataset supplies, so without a paired strap
// the line never runs and the row reads "Not connected".
//
// `--demo-sync` supplies a synthetic battery reading for the device row and cycles the syncing signal so
// the line runs on a loop instead of needing a real offload to be timed by hand.
//
// Gating: the WHOLE file is `#if DEBUG`, so it is stripped from every Release build. At runtime nothing
// changes unless `--demo-sync` is present: `active` stays false and Liquid Today's sync line and the
// quick-action device row read LiveState exactly as before, so the shipped controls are untouched. Everything here is SYNTHETIC — this is not a
// real battery reading and no strap is contacted.

enum DemoSyncHarness {

    /// True only when `--demo-sync` was passed (→ otherwise zero behaviour change).
    static private(set) var active = false

    /// The synthetic strap battery the control shows while the harness drives it. Mid-range and not
    /// charging, so the ring draws a partial arc — a full circle or the charging bolt would hide the
    /// arc-to-spinner part of the morph.
    static let batteryPercent: Double = 72
    static let charging = false

    /// Idle stretch between sync bursts. MUST comfortably exceed
    /// `StrandMotion.syncIndicatorSignalDebounceNanoseconds` (3s): LiquidBatteryButton debounces the
    /// falling edge by that much, so a shorter idle cancels the pending collapse and the capsule never
    /// morphs back — it just sits expanded with the spinner looping. 3s of debounce + ~2s visibly
    /// collapsed.
    static let idleSeconds: Double = 5.0

    /// Chunks "pulled" per burst, and the gap between them, so the expanded read-out ticks 1 → 2 → 3
    /// the way a real offload does rather than showing one frozen number.
    static let chunkTicks = 3
    static let chunkIntervalSeconds: Double = 1.2

    /// Scan the launch args for `--demo-sync`. Call ONCE at launch, beside DemoDayHarness. Safe to call
    /// always: with the flag absent `active` stays false and nothing changes. Idempotent.
    static func applyLaunchArgsIfNeeded() {
        active = CommandLine.arguments.contains("--demo-sync")
    }
}
#endif
