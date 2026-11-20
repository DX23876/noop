import Foundation

/// Whether the strap is handing history over right now, so the daily pass can wait a moment.
///
/// The Kotlin client holds a history chunk's ack until the core says it has banked that chunk, and gives
/// up after `CORE_ACK_WAIT_MS` (ten seconds). A held ack means the strap keeps the chunk and sends it
/// again next time, which is the safe outcome by design - but only as an exception. A tester's afternoon
/// made it the rule: 84 offload sessions, none completing, 672 holds over 107 distinct chunks, one chunk
/// held through two whole sessions and acked only in the third. No data was lost and the sync indicator
/// never cleared, while the strap's backlog fell seven hours behind overnight (#53, finding 1).
///
/// The cause is that the daily pass and the banking share one actor. `AnalysisRuns` already took the pass
/// out of the frame queue, which was the 2026-11-06 fix, but out of the queue is not off the actor: a
/// pass holding the main actor for longer than ten seconds still stops the frames behind it from being
/// banked, and over eighteen days of raw data it holds it for much longer than that.
///
/// So the pass yields to the strap. While history is arriving the pass waits, and the strap's handover -
/// a burst of five to thirteen chunks - finishes first. Nothing is skipped: a request that waits is
/// still a request, and the pass that eventually runs reads everything stored by then, which includes
/// what the offload just banked. The wearer is not kept waiting either, because the figures a pass
/// produces are a day's, not a second's.
///
/// Two bounds keep this from becoming its own fault. `idleGap` ends the hold once frames stop arriving,
/// because there is no "offload finished" event to listen for and a link that drops mid-handover would
/// otherwise hold forever. `maxHold` ends it regardless, so a strap with an enormous backlog, or one that
/// trickles frames indefinitely, cannot starve scoring: after that the pass runs and the ack it delays is
/// held, which is what used to happen every time and is survivable once.
public struct OffloadQuiet: Sendable {
    /// Quiet time after the last history frame before the handover counts as over.
    public let idleGap: TimeInterval
    /// The longest a single handover may hold the pass back, measured from its start.
    public let maxHold: TimeInterval

    private var startedAt: Date?
    private var lastFrameAt: Date?

    public init(idleGap: TimeInterval = 3, maxHold: TimeInterval = 90) {
        self.idleGap = idleGap
        self.maxHold = maxHold
    }

    /// A handover started.
    public mutating func began(at now: Date) {
        startedAt = now
        lastFrameAt = now
    }

    /// A history frame arrived.
    public mutating func frameArrived(at now: Date) {
        if startedAt == nil { startedAt = now }
        lastFrameAt = now
    }

    /// True while the daily pass should wait.
    public func holdsAnalysis(now: Date) -> Bool {
        guard let startedAt, let lastFrameAt else { return false }
        if now.timeIntervalSince(startedAt) >= maxHold { return false }
        return now.timeIntervalSince(lastFrameAt) < idleGap
    }
}

/// The session's view of [OffloadQuiet], on the actor the frame loop and the daily pass share.
///
/// A class rather than a value the loop owns, because the loop updates it while `AnalysisRuns` reads it,
/// and the two must be looking at the same handover.
@MainActor
public final class OffloadWatch {
    private var quiet: OffloadQuiet
    private let clock: @Sendable () -> Date

    public init(quiet: OffloadQuiet = OffloadQuiet(), clock: @escaping @Sendable () -> Date = Date.init) {
        self.quiet = quiet
        self.clock = clock
    }

    public func began() { quiet.began(at: clock()) }
    public func frameArrived() { quiet.frameArrived(at: clock()) }
    public func holdsAnalysis() -> Bool { quiet.holdsAnalysis(now: clock()) }
}
