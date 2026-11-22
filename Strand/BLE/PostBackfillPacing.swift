import Foundation

/// When the scoring pass that follows an offload may start.
///
/// Swift twin of `android/app/src/main/java/com/noop/ble/PostBackfillPacing.kt`, which was written for
/// this behaviour on THIS platform and says so: "as Apple's pass follows a completed backfill: started
/// between two chunks, as it did 1.5 s after the first one, it ran several hundred times a day over the
/// same days and competed with the very chunks it was scoring." Android has paced itself since; the Apple
/// side still fired on a two-second quiet window on `lastSyncedAt`, which is stamped once per offload
/// SESSION, not once per chain.
///
/// What that cost, from the owner's iPhone log of 2026-11-22:
///
///     07:53:45  session ended — reason=timeout outcome=drained · 141 rows
///     07:53:45  auto-continuing (#364/#451) ... re-kicking offload 1/24
///     07:54:47  re-score: trigger=post-offload newData=yes
///     07:57:30  sleep day=2026-11-22 totalSleepMin=123      ← the night, ending near 3 a.m.
///     07:59:51  session persisted 81886 rows
///     08:01:47  re-score: deferred — the last pass started 7 min ago; at most every 30 min
///     08:05:05  sleep day=2026-11-22 totalSleepMin=413      ← only after the wearer opened the app
///
/// The first slice of the chain brought the beginning of the night, the refresh fired two seconds after
/// it while the app had already decided to continue, and the pass published a night missing four hours —
/// to the dashboard, the widget and Apple Health. The correcting pass was then refused by the
/// thirty-minute background spacing the premature one had just spent.
///
/// So the wait is on the CHUNKS, not on the session bookkeeping: a chain that is still handing over data
/// is not quiet, whatever its session boundaries say.
///
/// ## Why the cap differs from the Kotlin twin
///
/// Android caps the wait at five minutes so "a long offload shows fresh values on the way". The chain
/// above ran about ten, so that cap would have published a partial night at 07:57 — later than today,
/// and still wrong. Here the cap is half an hour and serves only as a safety valve against a chain that
/// never goes quiet, because the cheap current-day refresh (steps, Effort) runs per slice regardless and
/// is what actually keeps the screen moving during a long offload. The rule is the same; the number
/// answers a different question on each platform, and the two tests pin their own.
enum PostBackfillPacing {

    /// No chunk for this long ⇒ the chain has stopped handing over data.
    static let quietSeconds: TimeInterval = 10

    /// Safety valve only: a chain that never goes quiet still gets a pass eventually. See the note above
    /// for why this is not the Kotlin twin's five minutes.
    static let maxWaitSeconds: TimeInterval = 1_800

    /// How often the wait re-checks.
    static let pollSeconds: TimeInterval = 0.5

    /// All three instants must come from ONE monotonic clock, as the Kotlin twin requires: measured
    /// across two clocks a tick apart, "quiet" can be a rounding artefact rather than an observation.
    ///
    /// `lastChunkAt` is nil when no chunk has been seen at all on this link — nothing is arriving, so
    /// there is nothing to wait for.
    static func keepWaiting(now: TimeInterval, waitStartedAt: TimeInterval, lastChunkAt: TimeInterval?) -> Bool {
        guard let lastChunkAt else { return false }
        return now - lastChunkAt < quietSeconds && now - waitStartedAt < maxWaitSeconds
    }
}
