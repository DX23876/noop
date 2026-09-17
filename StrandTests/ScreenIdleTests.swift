import XCTest
@testable import Strand

/// `ScreenIdle` tracks independent keep-awake holders by reason, because the platform idle-timer flag is a
/// single process-wide boolean: a strap sync finishing must not release the hold a breathing session or a
/// workout still needs, and vice versa. The platform write is a no-op on macOS, so this pins the hold set.
@MainActor
final class ScreenIdleTests: XCTestCase {
    private func releaseAll() {
        ScreenIdle.hold(.session, false)
        ScreenIdle.hold(.strapSync, false)
    }

    func testSyncEndingKeepsASessionHold() {
        releaseAll()
        ScreenIdle.keepAwake(true)
        ScreenIdle.hold(.strapSync, true)
        ScreenIdle.hold(.strapSync, false)
        XCTAssertTrue(ScreenIdle.isHeld)
        ScreenIdle.keepAwake(false)
        XCTAssertFalse(ScreenIdle.isHeld)
    }

    func testSessionEndingKeepsASyncHold() {
        releaseAll()
        ScreenIdle.hold(.strapSync, true)
        ScreenIdle.keepAwake(true)
        ScreenIdle.keepAwake(false)
        XCTAssertTrue(ScreenIdle.isHeld)
        ScreenIdle.hold(.strapSync, false)
        XCTAssertFalse(ScreenIdle.isHeld)
    }

    func testRepeatedReleaseIsHarmless() {
        releaseAll()
        ScreenIdle.hold(.strapSync, false)
        ScreenIdle.keepAwake(false)
        XCTAssertFalse(ScreenIdle.isHeld)
    }
}
