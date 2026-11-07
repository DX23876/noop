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

    func testTodayAndYesterdayStayOpen() {
        XCTAssertFalse(TimelineFeed.isFolded(day: "T", today: "T", yesterday: "Y", opened: []))
        XCTAssertFalse(TimelineFeed.isFolded(day: "Y", today: "T", yesterday: "Y", opened: []))
        XCTAssertTrue(TimelineFeed.isFolded(day: "W", today: "T", yesterday: "Y", opened: []))
        XCTAssertFalse(TimelineFeed.isFolded(day: "W", today: "T", yesterday: "Y", opened: ["W"]))
    }
}
