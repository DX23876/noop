import XCTest
import StrandAnalytics
@testable import Strand

final class TrainingDesignKitTests: XCTestCase {
    private let byDay: [String: Double] = [
        "2025-08-25": 3, "2025-09-01": 4, "2025-09-03": 5, "2025-09-10": 7, "2025-09-15": 6, "2025-09-17": 2,
        "2025-09-19": 9,
    ]

    func testTheWeekSpanShowsMondayToSundayAndLeavesDaysAheadEmpty() {
        let bars = LoadHistoryBuckets.bars(byDay: byDay, unknownDays: ["2025-09-16"], span: .week,
                                           readingDay: "2025-09-17")
        XCTAssertEqual(bars.map(\.start), ["2025-09-15", "2025-09-16", "2025-09-17", "2025-09-18",
                                           "2025-09-19", "2025-09-20", "2025-09-21"])
        XCTAssertEqual(bars.map(\.value), [6, 0, 2, nil, nil, nil, nil])
        XCTAssertEqual(bars.map(\.containsUnknown), [false, true, false, false, false, false, false])
        XCTAssertEqual(bars.filter(\.isSelected).map(\.start), ["2025-09-17"])
    }

    func testWeeklySpansEndWithTheReadWeekAndStopAtTheReadingDay() {
        let bars = LoadHistoryBuckets.bars(byDay: byDay, unknownDays: ["2025-09-02"], span: .fourWeeks,
                                           readingDay: "2025-09-17")
        XCTAssertEqual(bars.map(\.start), ["2025-08-25", "2025-09-01", "2025-09-08", "2025-09-15"])
        XCTAssertEqual(bars.map(\.value), [3, 9, 7, 8], "the 19th is after the reading day")
        XCTAssertEqual(bars.map(\.containsUnknown), [false, true, false, false])
        XCTAssertEqual(bars.map(\.isSelected), [false, false, false, true])
        XCTAssertEqual(LoadHistoryBuckets.bars(byDay: byDay, unknownDays: [], span: .twelveWeeks,
                                               readingDay: "2025-09-17").count, 12)
    }

    func testAPastWeekIsReadThroughItsSunday() {
        let bars = LoadHistoryBuckets.bars(byDay: byDay, unknownDays: [], span: .week, readingDay: "2025-09-07")
        XCTAssertEqual(bars.first?.start, "2025-09-01")
        XCTAssertEqual(bars.last?.isSelected, true)
        XCTAssertFalse(bars.contains { $0.value == nil })
    }

    func testThePillFollowsTheLaneBandAndSaysWhenThereIsNoComparison() {
        func lane(_ band: RelativeLoadBand?, guardState: LaneGuard = .none) -> TrainingLoadModel.Lane {
            let relative = TrainingLoad.relativeLoad(daily: [])
            let reading = LaneReading(day: "2026-09-24", relative: relative, thresholds: nil, band: band,
                                      guardState: guardState, daysBelowUsual: 0, followsHighPhase: false)
            return TrainingLoadModel.Lane(sevenDayTotal: 0, sevenDayWorkingSets: 0, trend: nil,
                                          relative: relative, isLowerBound: false,
                                          distribution: nil, weekOverWeek: nil, measuredCount: 0,
                                          possibleCount: 0, reading: reading)
        }
        XCTAssertEqual(LoadPillState.of(lane(.below)), .below)
        XCTAssertEqual(LoadPillState.of(lane(.usual)), .usual)
        XCTAssertEqual(LoadPillState.of(lane(.higher)), .higher)
        XCTAssertEqual(LoadPillState.of(lane(.muchHigher)), .muchHigher)
        XCTAssertEqual(LoadPillState.of(lane(nil)), .noComparison)
        XCTAssertEqual(LoadPillState.of(lane(nil, guardState: .tooFewSessions)), .tooFewSessions)
        XCTAssertFalse(LoadPillState.tooFewSessions.hasComparison)
        XCTAssertEqual(LoadPillState.of(lane(nil), provisional: true), .provisional)
        XCTAssertEqual(LoadPillState.of(nil), .noComparison)
    }

    func testSignedPercentHasNoDirectionWhenItRoundsToZero() {
        XCTAssertEqual(LoadFormat.signedPercent(18.4), "+18 %")
        XCTAssertEqual(LoadFormat.signedPercent(-7.6), "−8 %")
        XCTAssertEqual(LoadFormat.signedPercent(0.4), "0 %")
        XCTAssertEqual(LoadFormat.signedPercent(-0.4), "0 %")
    }
}
