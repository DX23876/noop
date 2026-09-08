import XCTest
import WhoopStore
@testable import Strand

final class TrendsPresentationTests: XCTestCase {
    private func day(_ key: String, recovery: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: 60, recovery: recovery,
            strain: 12, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }
    private var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12))!
    }

    func testSparseHistoryWidensEachMetricIndependently() {
        let rows = [day("2026-07-01", recovery: 61), day("2026-09-06", recovery: nil)]
        let metrics = TrendsView.prepare(days: rows, rest: ["2026-09-06": 78], range: .week, now: now)
        XCTAssertEqual(metrics["recovery"]?.effective, .quarter)
        XCTAssertEqual(metrics["recovery"]?.points.map(\.value), [61])
        XCTAssertEqual(metrics["rest"]?.effective, .week)
        XCTAssertEqual(metrics["rest"]?.points.map(\.value), [78])
        XCTAssertEqual(metrics["rhr"]?.points.map(\.value), [52])
    }

    func testRestCorrectionAtUnchangedDayCountChangesPreparedChart() {
        let rows = [day("2026-09-06", recovery: 70)]
        let before = TrendsView.prepare(days: rows, rest: ["2026-09-06": 60], range: .week, now: now)
        let after = TrendsView.prepare(days: rows, rest: ["2026-09-06": 85], range: .week, now: now)
        XCTAssertEqual(before["rest"]?.points.map(\.value), [60])
        XCTAssertEqual(after["rest"]?.points.map(\.value), [85])
        XCTAssertEqual(before["recovery"]?.points.map(\.value), after["recovery"]?.points.map(\.value))
    }

    func testEmptyHistoryProducesHonestEmptyWindows() {
        let metrics = TrendsView.prepare(days: [], rest: [:], range: .week, now: now)
        XCTAssertEqual(metrics.count, 5)
        for metric in metrics.values {
            XCTAssertTrue(metric.points.isEmpty)
            XCTAssertEqual(metric.effective, .all)
        }
    }
}
