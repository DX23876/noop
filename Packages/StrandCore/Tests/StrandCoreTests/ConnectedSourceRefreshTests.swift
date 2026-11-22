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

    /// It still makes no claim about freshness — but it does say the pull reached something, because a
    /// screen that stays silent reads as a gesture that did nothing.
    func testAPullThatOnlyAskedTheStrapSaysSoWithoutPromising() {
        XCTAssertEqual(Refresh.verdict([.init(source: .strap, brought: 40)]), .strapAsked)
    }

    func testNoAnswersAtAllSaysNothing() {
        XCTAssertNil(Refresh.verdict([]))
    }
}

extension ConnectedSourceRefreshTests {

    /// Apple's HealthKit sync answers with success or failure and no count. Reading that as "brought
    /// nothing" would let the line say everything is current in the same breath as three workouts
    /// arriving, so a source that cannot count says so.
    func testASourceThatCannotCountIsNotReadAsNothing() {
        let verdict = ConnectedSourceRefresh.verdict([.init(source: .health, brought: nil)])
        XCTAssertEqual(verdict, .refreshed)
    }

    func testACountedArrivalStillWinsOverAnUncountedOne() {
        let verdict = ConnectedSourceRefresh.verdict([.init(source: .health, brought: nil),
                                                      .init(source: .hevy, brought: 2)])
        XCTAssertEqual(verdict, .brought(total: 2))
    }

    func testAFailureStillWinsOverAnUncountedArrival() {
        let verdict = ConnectedSourceRefresh.verdict([.init(source: .health, brought: nil),
                                                      .init(source: .hevy, failed: true)])
        XCTAssertEqual(verdict, .partial(failed: [.hevy], brought: 0))
    }
}
