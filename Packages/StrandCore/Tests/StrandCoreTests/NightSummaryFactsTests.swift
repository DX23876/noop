import Foundation
import WhoopStore
import XCTest
@testable import StrandCore

/// The four figures a night is summed up in (`NightSummaryFacts`), which a tester asked to have back on
/// the Sleep page (2026-11-19) and which three screens used to work out for themselves.
final class NightSummaryFactsTests: XCTestCase {

    private func day(_ key: String, asleep: Double?, deep: Double?, rem: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: asleep, efficiency: nil, deepMin: deep, remMin: rem,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    private func days(_ count: Int, asleep: Double = 380, deep: Double = 110, rem: Double = 120) -> [DailyMetric] {
        (0..<count).map { day("2026-10-\(String(format: "%02d", $0 + 1))", asleep: asleep, deep: deep, rem: rem) }
    }

    /// The night the tester circled: 8h 37m in bed, 8h 13m asleep, 4h 40m of it restorative.
    func testTheNightsOwnFigures() {
        let night = NightSummaryFacts.Night(inBedMin: 517, asleepMin: 493, deepMin: 127, remMin: 154,
                                            storedEfficiency: nil)
        let facts = NightSummaryFacts.read(night: night, days: days(10))
        XCTAssertEqual(facts.inBedMin, 517)
        XCTAssertEqual(facts.asleepMin, 493)
        XCTAssertEqual(facts.restorativeMin, 281)
        XCTAssertEqual(facts.efficiencyPct!, 95.35, accuracy: 0.01)
    }

    /// The stored value is what the night was scored with, so it wins over a recount from the totals.
    func testTheStoredEfficiencyWins() {
        XCTAssertEqual(NightSummaryFacts.efficiencyPct(asleepMin: 493, inBedMin: 517, stored: 0.91)!,
                       91, accuracy: 0.0001)
        XCTAssertEqual(NightSummaryFacts.efficiencyPct(asleepMin: 493, inBedMin: 517, stored: 91)!,
                       91, accuracy: 0.0001)
    }

    /// A night that stored no efficiency and no stages has none to state. Better than a dash that reads
    /// as zero.
    func testNoEfficiencyWithoutANight() {
        XCTAssertNil(NightSummaryFacts.efficiencyPct(asleepMin: 0, inBedMin: 0, stored: nil))
        XCTAssertNil(NightSummaryFacts.efficiencyPct(asleepMin: 400, inBedMin: 0, stored: nil))
    }

    /// Asleep longer than the stages say in bed cannot exceed a full night.
    func testEfficiencyNeverPassesAHundred() {
        XCTAssertEqual(NightSummaryFacts.efficiencyPct(asleepMin: 500, inBedMin: 480, stored: nil)!, 100)
    }

    func testATypicalNeedsEnoughNights() {
        XCTAssertNil(NightSummaryFacts.typicalAsleepMin(days(4)))
        XCTAssertEqual(NightSummaryFacts.typicalAsleepMin(days(5))!, 380, accuracy: 0.0001)
        XCTAssertNil(NightSummaryFacts.typicalRestorativeMin(days(4)))
        XCTAssertEqual(NightSummaryFacts.typicalRestorativeMin(days(5))!, 230, accuracy: 0.0001)
    }

    /// Only the last thirty nights count, so a changed sleep pattern is not averaged against a year ago.
    func testTheTypicalLooksAtTheLastThirtyNights() {
        let old = days(40, asleep: 300, deep: 60, rem: 60)
        let recent = (0..<30).map { day("2026-11-\(String(format: "%02d", $0 + 1))", asleep: 480, deep: 120, rem: 140) }
        XCTAssertEqual(NightSummaryFacts.typicalAsleepMin(old + recent)!, 480, accuracy: 0.0001)
        XCTAssertEqual(NightSummaryFacts.typicalRestorativeMin(old + recent)!, 260, accuracy: 0.0001)
    }

    /// Restorative sleep is averaged per night, not as the sum of two separate means: a night with deep
    /// but no REM would otherwise raise one half over nights the other half never saw.
    func testTheRestorativeTypicalSkipsANightMissingAStage() {
        var rows = days(5, deep: 100, rem: 100)
        rows.append(day("2026-10-06", asleep: 400, deep: 100, rem: nil))
        XCTAssertEqual(NightSummaryFacts.typicalRestorativeMin(rows)!, 200, accuracy: 0.0001)
    }
}
