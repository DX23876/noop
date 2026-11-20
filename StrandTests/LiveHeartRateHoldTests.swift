import XCTest
@testable import Strand

/// The Live screen's hold on the realtime heart-rate stream.
///
/// Both faults these cover were one line: the screen took its hold only while the strap was connected
/// and bonded, and released whether or not it ever had one.
final class LiveHeartRateHoldTests: XCTestCase {

    /// The fault a tester reported: the screen was opened while the link was still coming up, and live
    /// heart rate never appeared although the link went on to be healthy. The hold must not depend on the
    /// link, because registering the want while offline is exactly how `BLEManager` is reached - its
    /// keep-alive tick and its post-bond branch both arm from a want that is already there.
    func testTheHoldIsTakenWithNoLinkYet() {
        var hold = LiveHeartRateHold()
        XCTAssertTrue(hold.take(isWhoop: true))
        XCTAssertTrue(hold.isHeld)
    }

    func testTakingTwiceArmsOnce() {
        var hold = LiveHeartRateHold()
        XCTAssertTrue(hold.take(isWhoop: true))
        // The link event that follows the appearance asks again; one appearance is one hold.
        XCTAssertFalse(hold.take(isWhoop: true))
        XCTAssertFalse(hold.take(isWhoop: true))
    }

    /// The second fault, and the sharper one: with a workout running, a screen that never took a hold
    /// used to release on the way out and take the workout's hold away - the #681 failure the ref-count
    /// exists to prevent.
    func testReleasingWithoutAHoldTakesNobodysAway() {
        var hold = LiveHeartRateHold()
        XCTAssertFalse(hold.release())
        XCTAssertFalse(hold.isHeld)
    }

    func testOneHoldIsGivenBackExactlyOnce() {
        var hold = LiveHeartRateHold()
        XCTAssertTrue(hold.take(isWhoop: true))
        XCTAssertTrue(hold.release())
        XCTAssertFalse(hold.release())
        XCTAssertFalse(hold.isHeld)
    }

    func testTakeAndReleaseStayPairedAcrossSeveralAppearances() {
        var hold = LiveHeartRateHold()
        var armed = 0
        for _ in 0..<5 {
            if hold.take(isWhoop: true) { armed += 1 }
            if hold.take(isWhoop: true) { armed += 1 }   // the link event's second ask
            if hold.release() { armed -= 1 }
        }
        XCTAssertEqual(0, armed, "every appearance must give back exactly what it took")
    }

    /// An Oura ring streams live heart rate through its own source and never went through this path.
    /// Keeping it out is what makes the release safe to call unconditionally on the way out.
    func testARingTakesNoHold() {
        var hold = LiveHeartRateHold()
        XCTAssertFalse(hold.take(isWhoop: false))
        XCTAssertFalse(hold.isHeld)
        XCTAssertFalse(hold.release())
    }

    /// A strap the registry resolves late: the appearance asked under a ring (or before the registry
    /// opened), the link event asks again once it is a WHOOP, and that is the ask that holds.
    func testAStrapResolvedAfterTheScreenOpenedStillGetsAHold() {
        var hold = LiveHeartRateHold()
        XCTAssertFalse(hold.take(isWhoop: false))
        XCTAssertTrue(hold.take(isWhoop: true))
        XCTAssertTrue(hold.isHeld)
    }
}
