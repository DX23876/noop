import Foundation

// SleepWindowSettledness.swift — is last night's window trustworthy enough to plan a day on?
//
// A user reported that the automatic wake time is often "far far earlier" than they actually woke, so
// their recovery reads wrong, and the coach hands them a plan built on it before they can correct the
// sleep by hand.
//
// The cause is not the staging algorithm. `SleepStager.detectSleep` runs over the raw streams that are
// PRESENT, and a strap that has only offloaded as far as 04:00 leaves no data after 04:00 — so the
// night it can see ends at 04:00 and the wearer is recorded as having woken there. The window is
// truncated by the sync, not misread. That failure is transient and self-healing: the next offload
// fills the gap and the night re-scores correctly.
//
// Which is exactly why the fix belongs here and not in the detector. Changing sleep detection would
// need validation against a varying input on real hardware (CLAUDE.md; WHOOP 4.0 motion is too sparse
// to stage reliably at all — see #345), and would be the wrong repair for a data-arrival problem.
// Instead: notice that the night is not settled yet, and don't let a coach speak with confidence about
// numbers that are still moving.
//
// Pure and clock-injected — no store, no `Date()`, no I/O — so every verdict is directly testable.
public enum SleepWindowSettledness {

    public enum Verdict: String, Equatable, Sendable {
        /// The window is supported by the data around it. Score it, plan on it.
        case settled
        /// The night ends exactly where the raw data ends, and that was a while ago — the strap has
        /// almost certainly not finished offloading. The recorded wake time is an artefact of the sync.
        case awaitingSync
        /// The data continues well past the recorded wake, and/or the wake sits far earlier than this
        /// wearer's learned habit. Suspicious rather than provably incomplete.
        case wakeLooksEarly
    }

    /// How close the last raw sample has to sit to the session's end before the window looks truncated
    /// BY the data rather than by the wearer waking. Two minutes: a genuine wake leaves the strap
    /// recording afterwards (you are awake, wearing it), so raw data stopping within a couple of minutes
    /// of the "wake" is the signature of a window cut off at the end of what has synced.
    public static let truncationToleranceSeconds = 120

    /// How long that truncation has to have persisted before it is worth acting on. Under this, a sync
    /// may simply be in flight; the wearer has only just woken and nothing is wrong yet.
    public static let staleTruncationSeconds = 45 * 60

    /// How much later than the recorded wake the data must continue before the wake looks early. An hour
    /// of further readings means the strap was on the wrist and recording while the wearer was supposedly
    /// already up — possible, but worth flagging rather than scoring silently.
    public static let dataOverrunSeconds = 60 * 60

    /// How far before the learned habitual wake counts as "far earlier". 90 minutes is well outside
    /// ordinary night-to-night variation, so this does not fire on a merely early morning.
    public static let habitDeviationSeconds = 90 * 60

    /// Judge one night.
    ///
    /// - Parameters:
    ///   - sessionEndTs: the detected wake (unix seconds).
    ///   - lastHrSampleTs: the newest raw HR sample stored for this device, or nil when unknown. Nil
    ///     disables the two data-shape checks rather than guessing — an unknown coverage edge is not
    ///     evidence of anything.
    ///   - nowTs: the current time.
    ///   - habitualWakeSec: the wearer's learned habitual wake as a LOCAL time-of-day in [0, 86400),
    ///     or nil during the cold start.
    ///   - offsetSec: seconds east of UTC, for turning `sessionEndTs` into a local time-of-day.
    ///
    /// `awaitingSync` is checked first: an objectively truncated window is a stronger statement than a
    /// suspicion, and a truncated night will usually ALSO look early against the habit — reporting the
    /// weaker verdict would send the wearer to fix a wake time that is about to fix itself.
    public static func verdict(sessionEndTs: Int,
                               lastHrSampleTs: Int?,
                               nowTs: Int,
                               habitualWakeSec: Int?,
                               offsetSec: Int) -> Verdict {
        if let lastHrSampleTs {
            let dataEndsAtWake = abs(lastHrSampleTs - sessionEndTs) <= truncationToleranceSeconds
            let longEnoughAgo = nowTs - sessionEndTs >= staleTruncationSeconds
            if dataEndsAtWake && longEnoughAgo { return .awaitingSync }
            if lastHrSampleTs - sessionEndTs >= dataOverrunSeconds { return .wakeLooksEarly }
        }
        if let habitualWakeSec, wakeIsEarlierThanHabit(sessionEndTs: sessionEndTs,
                                                      habitualWakeSec: habitualWakeSec,
                                                      offsetSec: offsetSec) {
            return .wakeLooksEarly
        }
        return .settled
    }

    /// Whether the recorded wake sits `habitDeviationSeconds` or more BEFORE the habitual wake, compared
    /// on the clock face so a 00:30 wake against a 23:45 habit is 45 minutes apart, not 23 hours. Only
    /// EARLIER counts: waking late is a lie-in, not a truncated recording.
    static func wakeIsEarlierThanHabit(sessionEndTs: Int, habitualWakeSec: Int, offsetSec: Int) -> Bool {
        let day = 86_400
        let wake = ((sessionEndTs + offsetSec) % day + day) % day
        // Signed shortest way round the clock from the habit to the actual wake; negative = earlier.
        var delta = wake - habitualWakeSec
        if delta > day / 2 { delta -= day }
        if delta < -day / 2 { delta += day }
        return delta <= -habitDeviationSeconds
    }
}
