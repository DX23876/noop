import XCTest
@testable import StrandCore
import StrandAnalytics

/// The core rules behind recipe AI-35: stored Rest traits and per-day local day windows.
final class AnalysisReviewAI35CoreTests: XCTestCase {

    // MARK: - RestTraitLookup

    func testANightReadsItsOwnStoredTraits() {
        let lookup = RestTraitLookup(needMinByDay: ["2026-10-20": 540], consistencyPctByDay: ["2026-10-20": 80])
        XCTAssertEqual(lookup.inputs(forDay: "2026-10-20"),
                       AnalyticsEngine.Rest.Inputs(needHours: 9, consistency: 0.8))
        XCTAssertEqual(lookup.needMin(forDay: "2026-10-20"), 540, accuracy: 1e-9)
    }

    /// A night the pass has not reached carries the newest EARLIER night's traits, never a later one's.
    func testAnUnscoredNightCarriesTheNewestEarlierTraits() {
        let lookup = RestTraitLookup(needMinByDay: ["2026-10-18": 500, "2026-10-19": 520, "2026-10-22": 600],
                                     consistencyPctByDay: ["2026-10-19": 70])
        XCTAssertEqual(lookup.inputs(forDay: "2026-10-21"),
                       AnalyticsEngine.Rest.Inputs(needHours: 520 / 60.0, consistency: 0.7))
    }

    func testNothingStoredIsTheColdStart() {
        XCTAssertEqual(RestTraitLookup.empty.inputs(forDay: "2026-10-21"), .coldStart)
        XCTAssertEqual(RestTraitLookup.empty.currentNeedMin(days: []), 480, accuracy: 1e-9)
    }

    /// The need tonight is the newest night's.
    func testTheCurrentNeedIsTheNewestNights() {
        let lookup = RestTraitLookup(needMinByDay: ["2026-10-01": 480, "2026-10-21": 530], consistencyPctByDay: [:])
        XCTAssertEqual(lookup.currentNeedMin(days: ["2026-10-01", "2026-10-21", "2026-10-11"]), 530, accuracy: 1e-9)
    }

    /// The stored points use the import's units, and a regularity still learning writes nothing.
    func testTraitPointsUseMinutesAndPercent() {
        let points = DailyAnalysis.restTraitPoints(day: "2026-10-20",
                                                   inputs: .init(needHours: 8.5, consistency: 0.9))
        XCTAssertEqual(points.map(\.key), ["sleep_need_min", "sleep_consistency"])
        XCTAssertEqual(points[0].value, 510, accuracy: 1e-9)
        XCTAssertEqual(points[1].value, 90, accuracy: 1e-9)
        XCTAssertEqual(DailyAnalysis.restTraitPoints(day: "2026-10-20", inputs: .coldStart).map(\.key),
                       ["sleep_need_min"])
    }

    // MARK: - Local day windows

    /// Europe/Berlin in a winter pass: 2026-11-10 00:00 CET is 23:00 UTC the day before (+3600). A day in
    /// August is on summer time (+7200), so its midnight is 22:00 UTC, an hour earlier than a fixed +3600
    /// put it.
    private static func berlin(_ ts: Int) -> Int {
        // CEST from 2026-03-29 01:00 UTC to 2026-10-25 01:00 UTC, CET otherwise.
        (1_774_746_000..<1_792_890_000).contains(ts) ? 7200 : 3600
    }

    func testASummerDayInAWinterPassStartsAtItsOwnMidnight() {
        let nowLocalMidnight = 1_794_265_200   // 2026-11-09 23:00 UTC = 2026-11-10 00:00 CET
        let august = DailyAnalysis.localDay(daysBefore: 92, nowLocalMidnight: nowLocalMidnight, nowOffset: 3600,
                                            offsetAt: Self.berlin)
        XCTAssertEqual(august.offsetSec, 7200)
        XCTAssertEqual(AnalyticsEngine.dayString(august.start, offsetSec: august.offsetSec), "2026-08-10")
        XCTAssertEqual(august.start % 86_400, 22 * 3600)   // 00:00 CEST
    }

    func testAWinterDayIsUnchanged() {
        let nowLocalMidnight = 1_794_265_200
        let day = DailyAnalysis.localDay(daysBefore: 5, nowLocalMidnight: nowLocalMidnight, nowOffset: 3600,
                                         offsetAt: Self.berlin)
        XCTAssertEqual(day.start, nowLocalMidnight - 5 * 86_400)
        XCTAssertEqual(day.offsetSec, 3600)
    }

    func testTheOffsetOfADayKeyIsReadAtItsNoon() {
        XCTAssertEqual(DailyAnalysis.utcOffset(forDayKey: "2026-08-10", offsetAt: Self.berlin), 7200)
        XCTAssertEqual(DailyAnalysis.utcOffset(forDayKey: "2026-11-10", offsetAt: Self.berlin), 3600)
    }
}
