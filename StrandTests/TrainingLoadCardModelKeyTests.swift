import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// PERF (chart-invalidation-and-tooltips): `TrainingLoadCard.result` used to re-run
/// `TrainingLoadEngine.evaluate` (a full-history EWMA scan) on every access, and TWICE per render. It's
/// now memoized behind `modelKey(for:)` + `@State` cache, mirroring `CompareView`'s `modelKey`/
/// `currentModel` idiom. `days` is `Repository.days` — a live-updating array whose LAST entry keeps
/// accumulating strain through the day — so unlike `CompareView.modelKey`'s count+endpoints idiom, this
/// key must change when a value inside the trailing window changes, not just when the day range/count
/// does. These pin that contract directly, without rendering the chart.
final class TrainingLoadCardModelKeyTests: XCTestCase {
    private func metric(day: String, strain: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: strain, exerciseCount: nil)
    }

    private func days(_ n: Int, strain: (Int) -> Double?) -> [DailyMetric] {
        (0..<n).map { metric(day: String(format: "2026-01-%02d", $0 + 1), strain: strain($0)) }
    }

    func testEmptyInputIsStable() {
        XCTAssertEqual(TrainingLoadCard.modelKey(for: []), TrainingLoadCard.modelKey(for: []))
    }

    func testIdenticalInputsProduceTheSameKey() {
        let a = days(10) { Double($0) }
        let b = days(10) { Double($0) }
        XCTAssertEqual(TrainingLoadCard.modelKey(for: a), TrainingLoadCard.modelKey(for: b))
    }

    func testLengtheningHistoryChangesTheKey() {
        let short = days(10) { Double($0) }
        let longer = days(11) { Double($0) }
        XCTAssertNotEqual(TrainingLoadCard.modelKey(for: short), TrainingLoadCard.modelKey(for: longer))
    }

    /// The regression this test guards: `days` is `Repository.days`, and its LAST entry (today,
    /// in progress) keeps its `day` string and the array's count fixed while `strain` keeps changing
    /// through the day as new samples arrive. A key built only from count + first/last DAY (the
    /// `CompareView.modelKey` idiom) would never invalidate here, and the training-load card would go
    /// stale until the calendar day rolled over.
    func testALiveUpdateToTodaysStrainWithSameCountAndDayRangeChangesTheKey() {
        var rows = days(5) { Double($0) }
        let beforeKey = TrainingLoadCard.modelKey(for: rows)
        // Same day, same count — only the last row's strain (today's, still accumulating) changes.
        let last = rows[rows.count - 1]
        rows[rows.count - 1] = metric(day: last.day, strain: (last.strain ?? 0) + 1)
        let afterKey = TrainingLoadCard.modelKey(for: rows)
        XCTAssertNotEqual(beforeKey, afterKey)
    }

    /// A day far enough back to fall outside the trailing `establishedDays` window doesn't affect the
    /// key's VALUE component directly — but the overall `days.count` still changes when it's removed
    /// (e.g. a re-import that drops a stale row), so that still invalidates the cache.
    func testDroppingTheOldestDayOutsideTheTrailingWindowStillChangesTheKey() {
        let established = TrainingLoadEngine.Configuration.standard.establishedDays
        let longHistory = days(established + 20) { Double($0) }
        let droppedOldest = Array(longHistory.dropFirst()) // removes the OLDEST day, well outside the tail
        XCTAssertNotEqual(TrainingLoadCard.modelKey(for: longHistory),
                           TrainingLoadCard.modelKey(for: droppedOldest),
                           "dropping a day must always invalidate, even outside the trailing window")
    }

    func testNilStrainIsDistinguishedFromAnyRealValue() {
        let withNil = days(5) { i in i == 2 ? nil : Double(i) }
        let withZero = days(5) { i in i == 2 ? 0 : Double(i) }
        XCTAssertNotEqual(TrainingLoadCard.modelKey(for: withNil), TrainingLoadCard.modelKey(for: withZero))
    }
}
