import XCTest
import StrandAnalytics
@testable import Strand

/// The short-nap review queue (fork issue #49): what it asks about, what it refuses to ask twice, and
/// what it forgets.
///
/// The queue exists because the detector is honest about not knowing: a still afternoon and a real nap
/// look alike from the wrist, so a candidate is offered rather than written. That only works if an offer
/// the wearer already answered never comes back, which is what these pin.
final class NapReviewStoreTests: XCTestCase {

    private let now = 1_763_400_000

    private func nap(start: Int, minutes: Int, hr: Int? = 54) -> PendingNap {
        PendingNap(NapDetector.Candidate(start: start, end: start + minutes * 60, meanHr: hr, confidence: 0.7))
    }

    /// A fresh window is worth asking about; the same window, already queued, is not.
    func testTheSameWindowIsNotQueuedTwice() {
        let candidate = nap(start: now - 3 * 3_600, minutes: 40)
        XCTAssertTrue(NapReviewStore.shouldEnqueue(candidate, pending: [], dismissedIds: []))
        XCTAssertFalse(NapReviewStore.shouldEnqueue(candidate, pending: [candidate], dismissedIds: []))
    }

    /// A window the wearer declined stays declined. Re-detecting it on the next offload must not ask
    /// again: the answer was "that was not sleep", and repeating the question is how an offer becomes a
    /// nuisance.
    func testADeclinedWindowIsNeverAskedAgain() {
        let candidate = nap(start: now - 4 * 3_600, minutes: 55)
        XCTAssertFalse(NapReviewStore.shouldEnqueue(candidate, pending: [], dismissedIds: [candidate.id]))
    }

    /// Two different windows are two different questions, even on the same afternoon.
    func testADifferentWindowIsItsOwnQuestion() {
        let first = nap(start: now - 5 * 3_600, minutes: 30)
        let second = nap(start: now - 2 * 3_600, minutes: 30)
        XCTAssertTrue(NapReviewStore.shouldEnqueue(second, pending: [first], dismissedIds: [first.id]))
    }

    /// Nothing waits forever. A candidate whose window ended more than the retention span ago is stale,
    /// not pending: answering it would write a nap into a day the wearer has long stopped thinking about.
    func testStaleCandidatesAreForgotten() {
        let fresh = nap(start: now - 2 * 3_600, minutes: 45)
        let old = nap(start: now - 40 * 3_600, minutes: 45)
        let kept = NapReviewStore.retained([old, fresh], now: now)
        XCTAssertEqual(kept.map(\.id), [fresh.id])
    }

    /// Newest first, so the question in front of the wearer is the one they can still remember.
    func testTheNewestQuestionComesFirst() {
        let older = nap(start: now - 6 * 3_600, minutes: 30)
        let newer = nap(start: now - 1 * 3_600, minutes: 30)
        XCTAssertEqual(NapReviewStore.retained([older, newer], now: now).map(\.id), [newer.id, older.id])
    }

    /// The declined list is pruned on the same rule, so it cannot grow without end — and a malformed id
    /// is dropped rather than kept forever as an unreadable entry.
    func testTheDeclinedListIsPrunedAndRefusesNonsense() {
        let fresh = nap(start: now - 3_600, minutes: 30).id
        let old = nap(start: now - 40 * 3_600, minutes: 30).id
        XCTAssertEqual(NapReviewStore.retainedIds([old, fresh, "nonsense"], now: now), [fresh])
    }

    /// A candidate carries its own length, which is what the card shows; the wearer decides on the clock
    /// window and the minutes, not on a confidence number.
    func testTheCandidateReportsItsLength() {
        XCTAssertEqual(nap(start: now - 3_600, minutes: 47).durationMin, 47)
    }
}
