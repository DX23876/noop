import Foundation

/// What prompted a sync attempt. Mirrors WHOOP (15-min periodic floor + event-triggered "process now"
/// syncs + the strap's own prompt events + manual), adapted to iOS.
enum BackfillTrigger {
    case periodic      // the repeating timer while connected+bonded
    case connect       // a (re)connect / bond confirmation
    case foreground    // the app became active (scenePhase .active)
    case manual        // the user tapped "Sync now"
    case strap         // an incoming strap EVENT packet (WHOOP's HighFreqSyncPrompt analog)
    case autoContinue  // #364: an immediate back-to-back continuation of a deep oldest-first backlog,
                       // fired right after a 60s idle-cap exit while still connected. Like .manual it
                       // bypasses the floor — the whole point is to NOT wait the 15-min periodic floor —
                       // but it's separately bounded by BLEManager's consecutive-cap + trim spin-detector,
                       // so it can't loop forever the way an un-floored periodic could.
}

/// Pure rate-limiter for historical-offload kicks. No BLE/store deps. Floors match WHOOP
/// (observed: ~15-min periodic + expedited event syncs).
enum BackfillPolicy {
    static let periodicFloorSeconds: TimeInterval = 900   // 15 min
    static let eventFloorSeconds: TimeInterval = 90       // absorbs reconnect-flaps / event bursts
    static let emptyBackoffThreshold = 3                  // empties before the floor starts stretching
    static let maxEmptyBackoff: Double = 4                // cap → ~6-min event / 1-hr periodic floor

    /// `emptyStreak` = consecutive COMPLETED offloads that banked no sensor records (EmptySyncTracker).
    /// Past the threshold the AUTOMATIC triggers (.periodic/.strap) stretch their floor — each further
    /// empty doubles it, capped — so an off-wrist / not-banking strap that still emits EVENT packets
    /// every 90s isn't re-offloaded console-only every 90s, draining its battery and ours (#77/#120/#216).
    /// `.manual`/`.connect`/`.foreground` never back off, and the first real record resets the streak,
    /// so baseline cadence resumes instantly — a user- or connection-driven sync is never delayed.
    ///
    /// `clockUntrusted` = the strap's own RTC currently reads future-dated (#928: `BackfillContinuation
    /// .isFutureDatedNewest`). Such a strap still BANKS real rows every pass, so it never trips the
    /// `emptyStreak` backoff above, yet #1012 already refuses to chase that range past one pass per
    /// connection — so the AUTOMATIC triggers get near-zero value from retrying it on the baseline
    /// cadence, at the cost of BLE airtime that competes with realtime HR streaming for the link (#160:
    /// reported as "HR not displaying while band is active" on a strap whose logs showed exactly this
    /// future-dated clock). Maxes the SAME backoff the empty-streak uses immediately — there's no
    /// "streak" to build for a clock fault the way there is for an empty offload, and it's the automatic
    /// triggers this exists to protect, so `.connect`/`.foreground`/`.manual`/`.autoContinue` stay
    /// un-floored exactly as they do for `emptyStreak`.
    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?, emptyStreak: Int = 0,
                          clockUntrusted: Bool = false) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        let backoff: Double
        if clockUntrusted {
            backoff = maxEmptyBackoff
        } else if emptyStreak >= emptyBackoffThreshold {
            backoff = min(pow(2.0, Double(emptyStreak - emptyBackoffThreshold + 1)), maxEmptyBackoff)
        } else {
            backoff = 1.0
        }
        switch trigger {
        // .manual (user-tapped) and .autoContinue (#364 expedited backlog drain) always run — both are
        // deliberately un-floored; .autoContinue's runaway protection lives in BLEManager's cap, not here.
        case .manual, .autoContinue: return true
        case .connect, .foreground:  return elapsed >= eventFloorSeconds
        case .strap:                 return elapsed >= eventFloorSeconds * backoff
        case .periodic:              return elapsed >= periodicFloorSeconds * backoff
        }
    }
}
