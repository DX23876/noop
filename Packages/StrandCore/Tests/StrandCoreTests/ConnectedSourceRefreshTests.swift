import XCTest
@testable import StrandCore

/// The rules behind the pull gesture: who may be asked, how often, and what one line says about several
/// answers. Both phones read them from here, so a disagreement between the two is a failure in this file
/// rather than a difference nobody notices until someone compares the screens.
final class ConnectedSourceRefreshTests: XCTestCase {

    private typealias Refresh = ConnectedSourceRefresh
    private typealias Source = ConnectedSourceRefresh.Source

    // MARK: - Who may be asked

    func testOnlyConnectedSourcesAreAsked() {
        let askable = Refresh.askable(connected: [.health], lastAsked: [:], now: 1_000)
        XCTAssertEqual(askable, [.health])
    }

    func testASourceNeverAskedIsAskable() {
        XCTAssertEqual(Refresh.askable(connected: [.hevy], lastAsked: [:], now: 0), [.hevy])
    }

    func testTheFloorHoldsOffARepeatedPull() {
        let askable = Refresh.askable(connected: [.health, .hevy],
                                      lastAsked: [.hevy: 990], now: 1_000)
        XCTAssertEqual(askable, [.health], "hevy was asked 10s ago, under the 30s floor")
    }

    func testTheFloorLetsGoAfterThirtySeconds() {
        let askable = Refresh.askable(connected: [.hevy], lastAsked: [.hevy: 970], now: 1_000)
        XCTAssertEqual(askable, [.hevy])
    }

    /// A clock that went backwards must not lock the gesture out until it catches up.
    func testAFutureStampCountsAsLongAgo() {
        let askable = Refresh.askable(connected: [.hevy], lastAsked: [.hevy: 9_999], now: 1_000)
        XCTAssertEqual(askable, [.hevy])
    }

    // MARK: - What the one line says

    func testNothingNewReadsAsUpToDate() {
        XCTAssertEqual(Refresh.verdict([.init(source: .health), .init(source: .hevy)]), .upToDate)
    }

    func testWhatArrivedIsCountedAcrossSources() {
        let verdict = Refresh.verdict([.init(source: .health, brought: 2),
                                       .init(source: .hevy, brought: 1)])
        XCTAssertEqual(verdict, .brought(total: 3))
    }

    func testAFailureIsNamedAndKeepsWhatArrived() {
        let verdict = Refresh.verdict([.init(source: .health, brought: 2),
                                       .init(source: .hevy, failed: true)])
        XCTAssertEqual(verdict, .partial(failed: [.hevy], brought: 2),
                       "naming only the failure would throw away the two that did arrive")
    }

    /// The strap runs for minutes and has its own progress; the line speaks for the services.
    func testTheStrapDoesNotDecideTheLine() {
        let verdict = Refresh.verdict([.init(source: .strap, brought: 40),
                                       .init(source: .health)])
        XCTAssertEqual(verdict, .upToDate)
    }

    func testAPullThatOnlyAskedTheStrapSaysNothing() {
        XCTAssertNil(Refresh.verdict([.init(source: .strap, brought: 40)]),
                     "claiming everything is current while an offload runs would be a promise nobody kept")
    }

    func testNoAnswersAtAllSaysNothing() {
        XCTAssertNil(Refresh.verdict([]))
    }
}
