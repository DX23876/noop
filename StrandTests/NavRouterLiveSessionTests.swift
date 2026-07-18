import XCTest
@testable import Strand

/// Pins the P3 fix: `openLiveSession()` used to only set `requestedDestination = .liveSession`, which
/// the shells (RootTabView/RootView) mapped to nothing more than switching to the Today tab — the
/// session screen itself is `LiquidTodayView`'s local `@State`, unreachable from routing alone. The
/// coach chat's "Live Session" action chip looked wired but did nothing beyond a tab switch. The fix
/// mirrors `openActiveWorkout()`'s established one-shot-flag pattern: `presentLiveSession`, consumed by
/// `LiquidTodayView.consumeLiveSessionRequest()`.
@MainActor
final class NavRouterLiveSessionTests: XCTestCase {

    func testFreshRouterHasNoPendingLiveSessionRequest() {
        let router = NavRouter()
        XCTAssertFalse(router.presentLiveSession)
    }

    func testOpenLiveSessionRaisesBothTheDestinationAndTheOneShotFlag() {
        let router = NavRouter()
        router.openLiveSession()
        XCTAssertTrue(router.presentLiveSession, "the one-shot flag is what actually opens the cover")
        XCTAssertEqual(router.requestedDestination, .liveSession, "and routing still lands on Today")
    }
}
