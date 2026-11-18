import XCTest
@testable import StrandAnalytics

final class TimelineFeedTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_700_000)
    private func days(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    func testANoticeStaysAtItsFirstMomentThroughTheDay() {
        let c = TimelineFeed.Candidate(key: "sleepCatchUp", topic: .sleep, severity: 3)
        let first = TimelineFeed.admit([c], log: [], day: "D1", now: t0)
        let later = TimelineFeed.admit([c], log: first.log, day: "D1", now: t0.addingTimeInterval(3600))
        XCTAssertEqual(later.admitted.map(\.at), [t0])
        XCTAssertEqual(later.log.count, 1)
    }

    /// "Your sleep was shorter for three nights" came six times in a month, nearly word for word.
    func testATopicIsQuietForSevenDaysUnlessItGotClearlyWorse() {
        let c = TimelineFeed.Candidate(key: "sleepCatchUp", topic: .sleep, severity: 2)
        var log = TimelineFeed.admit([c], log: [], day: "D1", now: t0).log
        XCTAssertTrue(TimelineFeed.admit([c], log: log, day: "D3", now: days(2)).admitted.isEmpty)
        let worse = TimelineFeed.Candidate(key: "restDayNeeded", topic: .sleep, severity: 3)
        let r = TimelineFeed.admit([worse], log: log, day: "D3", now: days(2))
        XCTAssertEqual(r.admitted.count, 1)
        log = r.log
        // The worse one is the topic's new reference.
        XCTAssertTrue(TimelineFeed.admit([worse], log: log, day: "D5", now: days(4)).admitted.isEmpty)
        XCTAssertEqual(TimelineFeed.admit([c], log: log, day: "D10", now: days(9.1)).admitted.count, 1)
    }

    func testEventsAndOtherTopicsAreNotHeldBack() {
        let log = TimelineFeed.admit([.init(key: "milestone|a", topic: .goals, severity: 1, isEvent: true)],
                                     log: [], day: "D1", now: t0).log
        let next = TimelineFeed.admit([.init(key: "milestone|b", topic: .goals, severity: 1, isEvent: true),
                                       .init(key: "strapBattery", topic: .device, severity: 3)],
                                      log: log, day: "D2", now: days(1))
        XCTAssertEqual(next.admitted.count, 2)
    }

    /// An event skips the topic's cooldown, so nothing else holds it back: without a rule of its own the
    /// SAME event would be admitted again every day it stays true. A streak reading "8 weeks in a row" is
    /// news on the day it starts, not every morning of that week.
    func testTheSameEventIsNewsOnlyOnce() {
        let streak = TimelineFeed.Candidate(key: "streak|8 weeks in a row", topic: .goals, severity: 1, isEvent: true)
        let first = TimelineFeed.admit([streak], log: [], day: "D1", now: t0)
        XCTAssertEqual(first.admitted.count, 1)
        // Still the same day: the entry stays where it first appeared.
        XCTAssertEqual(TimelineFeed.admit([streak], log: first.log, day: "D1", now: days(0.3)).admitted.first?.at, t0)
        // The following days say nothing new.
        XCTAssertTrue(TimelineFeed.admit([streak], log: first.log, day: "D2", now: days(1)).admitted.isEmpty)
        XCTAssertTrue(TimelineFeed.admit([streak], log: first.log, day: "D5", now: days(4)).admitted.isEmpty)
        // The next week IS a new fact, and says so.
        let grown = TimelineFeed.Candidate(key: "streak|9 weeks in a row", topic: .goals, severity: 1, isEvent: true)
        XCTAssertEqual(TimelineFeed.admit([grown], log: first.log, day: "D8", now: days(7)).admitted.count, 1)
    }

    /// The night-pending notice's shape: an event, so the device topic's cooldown cannot hold it back, and
    /// a FIXED key, because it reports a state rather than a change. Once-per-key would retire it after the
    /// first such morning for as long as the log remembers, and it is the only notice carrying the
    /// confirm-wake action, which the wearer can only use on a morning it is shown.
    func testAStandingConditionIsSaidEveryDayItHolds() {
        let night = TimelineFeed.Candidate(key: "nightPending", topic: .device, severity: 3,
                                           isEvent: true, repeats: true)
        let first = TimelineFeed.admit([night], log: [], day: "D1", now: t0)
        XCTAssertEqual(first.admitted.count, 1)
        let second = TimelineFeed.admit([night], log: first.log, day: "D2", now: days(1))
        XCTAssertEqual(second.admitted.count, 1, "the night is pending again, and so is the question")
        XCTAssertEqual(TimelineFeed.admit([night], log: second.log, day: "D3", now: days(2)).admitted.count, 1)
        // Still once per DAY: a second pass the same morning finds the entry it already placed.
        let again = TimelineFeed.admit([night], log: second.log, day: "D2", now: days(1.4))
        XCTAssertEqual(again.admitted.first?.at, days(1))
        XCTAssertEqual(again.log.filter { $0.key == "nightPending" && $0.day == "D2" }.count, 1)
    }

    /// The cooldown bypass is what `isEvent` buys, and `repeats` must not cost it: a louder notice on the
    /// same topic the day before cannot silence the standing one.
    func testAStandingConditionStillSkipsTheTopicsCooldown() {
        let battery = TimelineFeed.Candidate(key: "strapBattery", topic: .device, severity: 4)
        let night = TimelineFeed.Candidate(key: "nightPending", topic: .device, severity: 3,
                                           isEvent: true, repeats: true)
        let log = TimelineFeed.admit([battery], log: [], day: "D1", now: t0).log
        XCTAssertEqual(TimelineFeed.admit([night], log: log, day: "D2", now: days(1)).admitted.count, 1)
    }

    func testTheLogForgetsAfterThirtyDays() {
        let log = TimelineFeed.admit([.init(key: "k", topic: .load, severity: 2)], log: [], day: "D1", now: t0).log
        XCTAssertTrue(TimelineFeed.admit([], log: log, day: "D40", now: days(31)).log.isEmpty)
    }

    func testOnlyDetectedOrImportedWalksBundleAndOnlyFromTwo() {
        let key: (Date) -> String = { $0 < self.days(1) ? "D1" : "D2" }
        let walks = [
            TimelineFeed.Walk(id: "a", start: t0, end: t0.addingTimeInterval(1200), bundles: true),
            TimelineFeed.Walk(id: "b", start: t0.addingTimeInterval(7200), end: t0.addingTimeInterval(9000), bundles: true),
            TimelineFeed.Walk(id: "c", start: t0.addingTimeInterval(10_000), end: t0.addingTimeInterval(12_000), bundles: false),
            TimelineFeed.Walk(id: "d", start: days(1.2), end: days(1.25), bundles: true),
        ]
        let bundles = TimelineFeed.walkBundles(walks, dayKey: key)
        XCTAssertEqual(bundles.keys.sorted(), ["D1"])
        XCTAssertEqual(bundles["D1"]?.map(\.id), ["a", "b"])
        XCTAssertEqual(bundles["D1"]?.reduce(0) { $0 + $1.minutes }, 50)
    }

    func testOnlyTodayAndYesterdayAreShown() {
        XCTAssertTrue(TimelineFeed.isShown(day: "T", today: "T", yesterday: "Y"))
        XCTAssertTrue(TimelineFeed.isShown(day: "Y", today: "T", yesterday: "Y"))
        XCTAssertFalse(TimelineFeed.isShown(day: "W", today: "T", yesterday: "Y"))
    }
}
