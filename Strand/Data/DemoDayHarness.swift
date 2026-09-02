#if DEBUG
import Foundation
import StrandAnalytics

// MARK: - DEBUG-only day-cycle screenshot harness
//
// A promo-animation aid (NOT shipped). When the process is launched with `--demo-hour <Int>` (the two
// args arrive separately via `simctl launch`), this pins the Today screen to a single believable
// "moment in the day": it swaps the day-cycle SCENE to that hour's illustration and overrides a small
// set of Today read-outs (Effort, greeting, readiness badge, Synthesis copy, and the Stress / HRV /
// Resting-HR cards) with a hand-tuned per-hour value so a sweep of `--demo-hour 2 … 22` captures every
// background with a plausible stat progression across the day.
//
// Gating: the WHOLE file is `#if DEBUG`, so it is stripped from every Release build. At runtime nothing
// changes unless `--demo-hour` is present: `applyLaunchArgsIfNeeded()` leaves `active == nil` otherwise,
// and every override in TodayView is `(DemoDayHarness.active != nil)`-gated — so with no arg the screen
// is byte-identical to the seeded demo. Pairs with `--demo-seed` (AppleDemoSeeder), which supplies the
// underlying synthetic dataset; this harness only re-presents a few values on top of it. Everything here
// is SYNTHETIC — nothing is real biometric data.

/// One pinned "moment in the day" the harness renders. All values are presentation-only overrides.
struct DemoDayFrame {
    let hour: Int
    let greeting: String
    let readiness: String
    let effort: Double      // NOOP 0–100 Effort axis
    let hrvMs: Int
    let rhrBpm: Int
    let stress0to3: Int
    /// The leading Momentum message's headline and detail for this hour.
    ///
    /// These were written for the OLD status card, which said one thing about the day regardless of
    /// topic — so pairing them with a typed Momentum message produced captures like a walking icon and
    /// a "7,660 / 10,000" chip under the headline "Pushing". They now read as the message they belong
    /// to. (Field names kept: they are the harness's own, and every call site is in this feature.)
    let synthHeadline: String
    let synthBody: String
    /// Which Momentum message leads this hour, and how it reads.
    ///
    /// The harness used to override the Momentum card with a single, tone-less message, which made the
    /// one thing the card exists to demonstrate — that it CHANGES through the day, in kind and in
    /// colour — invisible in exactly the sweep meant to show it off. Now each captured hour names the
    /// message that should lead it, so `--demo-hour 2 … 22` walks the morning recovery read, the
    /// afternoon activity read and the evening sleep read, each in its own tone.
    let momentumKind: MomentumKind
    let momentumTone: MomentumTone
    /// Optional progress read-out for the leading message ("7,660 / 10,000").
    var momentumProgress: (fraction: Double, label: String)? = nil
}

enum DemoDayHarness {

    /// The pinned frame, or nil when `--demo-hour` was not passed (→ zero behaviour change).
    static private(set) var active: DemoDayFrame?

    /// The override hour for the day-cycle scene, when a frame is active.
    static var hour: Int? { active?.hour }

    /// The ten frames, one per captured hour, ordered through the day. Hand-tuned so the stat
    /// progression reads believably as the day advances (Effort climbs and settles, HRV/RHR ebb and
    /// flow, stress peaks midday). The scene each hour resolves to is owned by `DayCycleScene`.
    static let frames: [DemoDayFrame] = [
        DemoDayFrame(hour: 2,  greeting: "Good night",     readiness: "Solid",    effort: 3,  hrvMs: 84, rhrBpm: 50, stress0to3: 0,
                     synthHeadline: "You're short on sleep this week", synthBody: "About 3 h 20 min behind your nightly need.",
                     momentumKind: .sleepCatchUp, momentumTone: .caution),
        DemoDayFrame(hour: 5,  greeting: "Early start",    readiness: "Solid",    effort: 5,  hrvMs: 81, rhrBpm: 51, stress0to3: 0,
                     synthHeadline: "Strong recovery this morning", synthBody: "HRV is well above your baseline and resting HR is low.",
                     momentumKind: .recoveryRead, momentumTone: .positive, momentumProgress: (0.86, "86 / 100")),
        DemoDayFrame(hour: 6,  greeting: "Good morning",   readiness: "Solid",    effort: 7,  hrvMs: 78, rhrBpm: 53, stress0to3: 1,
                     synthHeadline: "Rested and ready", synthBody: "You're recovered and set for whatever today asks.",
                     momentumKind: .recoveryRead, momentumTone: .positive, momentumProgress: (0.84, "84 / 100")),
        DemoDayFrame(hour: 7,  greeting: "Good morning",   readiness: "Solid",    effort: 11, hrvMs: 73, rhrBpm: 57, stress0to3: 1,
                     synthHeadline: "Today looks like a good training day", synthBody: "Recovery is high and this week's load is still moderate.",
                     momentumKind: .trainingSuggestion, momentumTone: .positive),
        DemoDayFrame(hour: 8,  greeting: "Good morning",   readiness: "Moderate", effort: 18, hrvMs: 67, rhrBpm: 61, stress0to3: 2,
                     synthHeadline: "Running is still open", synthBody: "You planned it for today and nothing has been recorded yet.",
                     momentumKind: .planDeviation, momentumTone: .caution),
        DemoDayFrame(hour: 10, greeting: "Good morning",   readiness: "Moderate", effort: 31, hrvMs: 62, rhrBpm: 64, stress0to3: 2,
                     synthHeadline: "6,900 steps to your goal", synthBody: "You're at 3,100 of 10,000 today.",
                     momentumKind: .stepGoal, momentumTone: .neutral, momentumProgress: (0.31, "3,100 / 10,000")),
        DemoDayFrame(hour: 14, greeting: "Good afternoon", readiness: "Moderate", effort: 56, hrvMs: 55, rhrBpm: 71, stress0to3: 2,
                     synthHeadline: "2,340 steps to your goal", synthBody: "You're at 7,660 of 10,000 today.",
                     momentumKind: .stepGoal, momentumTone: .neutral, momentumProgress: (0.77, "7,660 / 10,000")),
        DemoDayFrame(hour: 17, greeting: "Good evening",   readiness: "Moderate", effort: 69, hrvMs: 58, rhrBpm: 66, stress0to3: 1,
                     synthHeadline: "One session short of your week", synthBody: "You've done 2 of 3 this week.",
                     momentumKind: .weeklyTrainingGoal, momentumTone: .neutral, momentumProgress: (0.67, "2 / 3")),
        DemoDayFrame(hour: 19, greeting: "Good evening",   readiness: "Solid",    effort: 77, hrvMs: 63, rhrBpm: 61, stress0to3: 1,
                     synthHeadline: "5 days in a row", synthBody: "You've hit your goal 5 days running.",
                     momentumKind: .streak, momentumTone: .positive),
        DemoDayFrame(hour: 22, greeting: "Good night",     readiness: "Solid",    effort: 84, hrvMs: 71, rhrBpm: 55, stress0to3: 0,
                     synthHeadline: "You're short on sleep this week", synthBody: "About 3 h 20 min behind your nightly need.",
                     momentumKind: .sleepCatchUp, momentumTone: .caution),
    ]

    /// Scan the launch args for `--demo-hour <Int>` and pin the matching frame (exact hour, else the
    /// nearest by absolute hour distance). Call ONCE at launch before the first Today render. Safe to
    /// call always: with no `--demo-hour` present `active` stays nil and nothing changes. Idempotent.
    static func applyLaunchArgsIfNeeded() {
        let args = CommandLine.arguments
        // `--demo-hour` and its value arrive as two separate args (simctl). Find the flag, read the next.
        guard let flagIdx = args.firstIndex(of: "--demo-hour"),
              args.index(after: flagIdx) < args.endIndex,
              let wanted = Int(args[args.index(after: flagIdx)]) else { return }
        guard !frames.isEmpty else { return }
        active = frames.first(where: { $0.hour == wanted })
            ?? frames.min(by: { abs($0.hour - wanted) < abs($1.hour - wanted) })
    }
}
#endif
