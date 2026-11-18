import XCTest
@testable import Strand

/// The Today notice for a night that is still being scored: its words come from the one resolver both
/// surfaces read, and it offers both answers, which it did not until 2026-11-18.
@MainActor
final class ForgeNightPendingNoticeTests: XCTestCase {
    private let wake = 1_763_446_320
    private var defaults: UserDefaults!

    override func setUp() {
        // Its own suite: `notices` writes the shown-log into defaults, and a test must not inherit or
        // leave one.
        defaults = UserDefaults(suiteName: "forge-notice-\(UUID().uuidString)")!
    }

    private func notices(fetching: Bool) -> [ForgeTimeline.Notice] {
        let reading = UnsettledNightReadout.reading(wakeTs: wake, fetching: fetching)
        return ForgeNotices.notices(momentum: [], nightPending: reading, day: "2026-11-18",
                                    now: Date(timeIntervalSince1970: TimeInterval(wake + 3600)),
                                    defaults: defaults)
    }

    func testTheNoticeCarriesTheResolversWords() {
        guard let notice = notices(fetching: true).first(where: { $0.key == ForgeNotices.nightPendingKey })
        else { return XCTFail("a pending night is worth a notice") }
        let reading = UnsettledNightReadout.reading(wakeTs: wake, fetching: true)
        XCTAssertEqual(notice.headline, reading.headline)
        XCTAssertEqual(notice.detail, reading.line)
    }

    /// Either the detected wake was the wake, or it was not. The classic morning card has offered both
    /// ways out since it was written; this notice offered only the first.
    func testTheNoticeOffersBothAnswers() {
        guard let notice = notices(fetching: false).first(where: { $0.key == ForgeNotices.nightPendingKey })
        else { return XCTFail("a pending night is worth a notice") }
        XCTAssertEqual(notice.action, .confirmWake)
        XCTAssertEqual(notice.secondaryAction, .sleep)
        XCTAssertNotNil(notice.actionTitle)
        XCTAssertNotNil(notice.secondaryActionTitle)
    }

    /// The reason differs with the state, so the two readings must not produce the same detail.
    func testTheDetailFollowsWhetherSomethingIsComingIn() {
        let running = notices(fetching: true).first { $0.key == ForgeNotices.nightPendingKey }?.detail
        defaults = UserDefaults(suiteName: "forge-notice-\(UUID().uuidString)")!
        let idle = notices(fetching: false).first { $0.key == ForgeNotices.nightPendingKey }?.detail
        XCTAssertNotNil(running)
        XCTAssertNotEqual(running, idle)
    }

    /// Today's hint card shows a notice's words but not its answers, and its body used to run the first
    /// action on a plain tap: tapping "Still being scored" vouched for the detected wake time, which the
    /// card never said. Any action that CHANGES something now has to name itself.
    func testAnActionThatCommitsIsMarkedAsOne() {
        XCTAssertTrue(ForgeTimeline.Notice.Action.confirmWake.commits)
        for action in [ForgeTimeline.Notice.Action.none, .charge, .plan, .goals, .sleep] {
            XCTAssertFalse(action.commits, "\(action) opens a screen; only a change needs a label")
        }
    }

    func testNoPendingNightMeansNoSuchNotice() {
        let out = ForgeNotices.notices(momentum: [], nightPending: nil, day: "2026-11-18",
                                       now: Date(timeIntervalSince1970: TimeInterval(wake + 3600)),
                                       defaults: defaults)
        XCTAssertFalse(out.contains { $0.key == ForgeNotices.nightPendingKey })
    }
}
