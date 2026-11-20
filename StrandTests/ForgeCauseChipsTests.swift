import XCTest
@testable import Strand
import StrandAnalytics

/// Which notices may ask what explains them (reported 2026-11-20).
///
/// The question is there to CALM a warning. It was drawn from the topic alone, and `bodySignals` carries
/// the HRV run in both directions, so a reader three days ABOVE baseline was asked whether illness,
/// alcohol, travel or stress explained the good news.
final class ForgeCauseChipsTests: XCTestCase {
    private func notice(topic: TimelineFeed.Topic, tone: ForgeTimeline.Notice.Tone) -> ForgeTimeline.Notice {
        ForgeTimeline.Notice(key: "k", date: Date(timeIntervalSince1970: 1_763_600_000),
                             topic: topic.rawValue, tone: tone,
                             headline: "h", detail: "d")
    }

    func testTheGoodNewsAsksNothing() {
        XCTAssertFalse(notice(topic: .bodySignals, tone: .positive).asksForCause,
                       "HRV above baseline for three days needs no explanation")
        XCTAssertFalse(notice(topic: .bodySignals, tone: .neutral).asksForCause)
    }

    func testAWarningAsks() {
        XCTAssertTrue(notice(topic: .bodySignals, tone: .caution).asksForCause)
        XCTAssertTrue(notice(topic: .bodySignals, tone: .critical).asksForCause)
    }

    func testOnlyBodySignalsAsk() {
        for topic in [TimelineFeed.Topic.sleep, .load, .movement, .goals, .device] {
            XCTAssertFalse(notice(topic: topic, tone: .critical).asksForCause,
                           "\(topic) has no cause chips to offer")
        }
    }

    /// The two messages that share the topic, as Momentum builds them: the warning asks, the good news
    /// does not. Guards the mapping itself, not only the property.
    func testTheHrvRunAsksOnlyWhenItWarns() {
        XCTAssertEqual(ForgeNotices.topic(for: .hrvTrend), .bodySignals)
        XCTAssertEqual(ForgeNotices.topic(for: .healthAlert), .bodySignals)
        XCTAssertTrue(notice(topic: .bodySignals, tone: .caution).asksForCause)
        XCTAssertFalse(notice(topic: .bodySignals, tone: .positive).asksForCause)
    }
}
