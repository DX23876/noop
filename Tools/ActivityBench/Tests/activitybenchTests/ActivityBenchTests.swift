import StrandAnalytics
import XCTest

@testable import activitybench

final class ActivityBenchTests: XCTestCase {
    private func row(_ source: String, bundle: String? = nil, start: Int = 0, end: Int = 600) -> EntryRow {
        EntryRow(startTs: start, endTs: end, sport: "Walking", source: source, bundleId: bundle)
    }

    func testOnlyTheWearersOwnEntriesAreGroundTruth() {
        XCTAssertTrue(EntryFilter.isWearerEntry(row("manual"), ownBundleMarker: "noop"))
        XCTAssertTrue(EntryFilter.isWearerEntry(row("apple-health", bundle: "com.apple.Fitness"), ownBundleMarker: "noop"))
        XCTAssertFalse(EntryFilter.isWearerEntry(row("my-whoop-noop"), ownBundleMarker: "noop"))
        XCTAssertFalse(EntryFilter.isWearerEntry(row("detected-confirmed"), ownBundleMarker: "noop"))
        XCTAssertFalse(EntryFilter.isWearerEntry(row("apple-health", bundle: "org.example.NoopForge"), ownBundleMarker: "noop"))
        XCTAssertFalse(EntryFilter.isWearerEntry(row("manual", start: 600, end: 600), ownBundleMarker: "noop"))
    }

    func testWeeksTallyHitsEntriesAndWornDaysApart() {
        let outcomes: [Outcome] = [
            .init(week: 0, what: .suggestion(found: .walk)), .init(week: 0, what: .entry(.walk)),
            .init(week: 0, what: .suggestion(found: nil)), .init(week: 0, what: .wornDay),
            .init(week: 1, what: .entry(.strength)), .init(week: 1, what: .wornDay), .init(week: 1, what: .wornDay),
        ]
        let weeks = WeekTally.byWeek(outcomes)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0].hits, [.walk: 1])
        XCTAssertEqual(weeks[0].unlabelled, 1)
        XCTAssertEqual(WeekTally.sum(weeks).wornDays, 3)
        XCTAssertEqual(WeekTally.sum(weeks).entries, [.walk: 1, .strength: 1])
    }

    func testTheIntervalIsSeededAndBracketsTheEstimate() {
        let weeks = (0..<8).map { i in
            var w = WeekTally()
            w.unlabelled = i % 3
            w.wornDays = 7
            return w
        }
        let stat: (WeekTally) -> Double? = { t in Double(t.unlabelled) / Double(t.wornDays) }
        let a = WeekBootstrap.interval(weeks, statistic: stat)
        let b = WeekBootstrap.interval(weeks, statistic: stat)
        XCTAssertEqual(a?.low, b?.low)
        XCTAssertEqual(a?.high, b?.high)
        let point = stat(WeekTally.sum(weeks))!
        XCTAssertLessThanOrEqual(a!.low, point)
        XCTAssertGreaterThanOrEqual(a!.high, point)
        XCTAssertNil(WeekBootstrap.interval([weeks[0]], statistic: stat))
    }
}
