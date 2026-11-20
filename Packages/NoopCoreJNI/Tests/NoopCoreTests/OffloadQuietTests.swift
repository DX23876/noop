import XCTest
@testable import NoopCore

/// When the daily pass yields to the strap (#53, finding 1).
final class OffloadQuietTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testNothingIsHeldBeforeAHandoverStarts() {
        let quiet = OffloadQuiet()
        XCTAssertFalse(quiet.holdsAnalysis(now: t0))
    }

    /// The burst the tester's log shows is five to thirteen chunks, arriving back to back. Throughout it
    /// the pass waits, so the chunks are banked and the client's acks go out inside its ten seconds.
    func testThePassWaitsWhileFramesKeepArriving() {
        var quiet = OffloadQuiet(idleGap: 3, maxHold: 90)
        quiet.began(at: t0)
        XCTAssertTrue(quiet.holdsAnalysis(now: t0))
        for second in stride(from: 1.0, through: 30.0, by: 1.0) {
            quiet.frameArrived(at: t0.addingTimeInterval(second))
            XCTAssertTrue(quiet.holdsAnalysis(now: t0.addingTimeInterval(second + 0.5)),
                          "held while history is still arriving (\(second)s in)")
        }
    }

    /// There is no "offload finished" event to listen for, and a link that drops mid-handover sends no
    /// more frames. Quiet is what ends the hold, so a dropped link cannot hold the pass for ever.
    func testQuietEndsTheHold() {
        var quiet = OffloadQuiet(idleGap: 3, maxHold: 90)
        quiet.began(at: t0)
        quiet.frameArrived(at: t0.addingTimeInterval(5))
        XCTAssertTrue(quiet.holdsAnalysis(now: t0.addingTimeInterval(7.9)))
        XCTAssertFalse(quiet.holdsAnalysis(now: t0.addingTimeInterval(8.1)))
    }

    /// A strap with an enormous backlog, or one trickling frames indefinitely, must not starve scoring.
    /// Past the ceiling the pass runs and the ack it delays is held - which is what used to happen every
    /// time, and is survivable once.
    func testTheCeilingEndsTheHoldEvenWhileFramesArrive() {
        var quiet = OffloadQuiet(idleGap: 3, maxHold: 90)
        quiet.began(at: t0)
        quiet.frameArrived(at: t0.addingTimeInterval(89))
        XCTAssertTrue(quiet.holdsAnalysis(now: t0.addingTimeInterval(89.5)))
        quiet.frameArrived(at: t0.addingTimeInterval(120))
        XCTAssertFalse(quiet.holdsAnalysis(now: t0.addingTimeInterval(120.1)),
                       "the ceiling is measured from the start of the handover, not from the last frame")
    }

    /// A frame before any begin still counts as a handover: the client reconnects mid-offload and the
    /// core sees records without a fresh start.
    func testAFrameWithoutABeginStartsTheHandover() {
        var quiet = OffloadQuiet(idleGap: 3, maxHold: 90)
        quiet.frameArrived(at: t0)
        XCTAssertTrue(quiet.holdsAnalysis(now: t0.addingTimeInterval(1)))
    }

    /// A handover that ended long ago must not hold a pass requested later.
    func testAnOldHandoverHoldsNothing() {
        var quiet = OffloadQuiet(idleGap: 3, maxHold: 90)
        quiet.began(at: t0)
        quiet.frameArrived(at: t0.addingTimeInterval(2))
        XCTAssertFalse(quiet.holdsAnalysis(now: t0.addingTimeInterval(600)))
    }

    /// The watch is what the frame loop writes and the pass reads; they must see one handover.
    @MainActor
    func testTheWatchReadsTheSameHandoverTheLoopWrites() {
        let clock = NowBox(t0)
        let watch = OffloadWatch(quiet: OffloadQuiet(idleGap: 3, maxHold: 90), clock: { clock.value })
        XCTAssertFalse(watch.holdsAnalysis())

        watch.began()                                   // the loop: a handover started
        XCTAssertTrue(watch.holdsAnalysis())            // the pass: wait

        clock.value = t0.addingTimeInterval(2)
        watch.frameArrived()                            // the loop: history still arriving
        clock.value = t0.addingTimeInterval(4)
        XCTAssertTrue(watch.holdsAnalysis())

        clock.value = t0.addingTimeInterval(6)          // quiet for longer than the gap
        XCTAssertFalse(watch.holdsAnalysis())
    }
}

/// A settable instant for a `@Sendable` clock closure in a test.
private final class NowBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
