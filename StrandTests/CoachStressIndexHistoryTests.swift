import XCTest
import StrandAnalytics
@testable import Strand

/// Pins T3.3 of Etappe T: `get_stress_index` used to return a single Baevsky Stress Index scalar for
/// today; `AICoachEngine.daytimeStressLine` adds the hourly history `DaytimeStress.analyze` already
/// computes for the Stress screen's timeline, so the coach can say WHEN today ran high, not just by how
/// much overall. Pure (no store) — mirrors the existing `stressIndexSummary` split.
final class CoachStressIndexHistoryTests: XCTestCase {

    private func point(_ hour: Int, level: Double?) -> DaytimeStress.HourPoint {
        DaytimeStress.HourPoint(hour: hour, startTs: hour * 3_600, level: level, meanHR: nil, rmssd: nil)
    }

    func testNoScoredHoursMeansNoLine() {
        let result = DaytimeStress.Result(hours: [point(8, level: nil), point(9, level: nil)],
                                          sustainedHigh: false, sustainedRun: 0, dayMean: nil, peak: nil)
        XCTAssertNil(AICoachEngine.daytimeStressLine(result))
    }

    func testScoredHoursListEachLevel() {
        let result = DaytimeStress.Result(
            hours: [point(8, level: 1.2), point(9, level: 1.8)],
            sustainedHigh: false, sustainedRun: 0, dayMean: 1.5, peak: nil)
        let line = AICoachEngine.daytimeStressLine(result)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("08:00 1.2"))
        XCTAssertTrue(line!.contains("09:00 1.8"))
    }

    func testPeakHourIsCalledOut() {
        let peak = point(14, level: 2.6)
        let result = DaytimeStress.Result(hours: [point(13, level: 1.0), peak],
                                          sustainedHigh: false, sustainedRun: 0, dayMean: 1.8, peak: peak)
        let line = AICoachEngine.daytimeStressLine(result)
        XCTAssertTrue(line!.contains("peak 14:00 (2.6)"))
    }

    func testSustainedHighIsCalledOutWithTheRunLength() {
        let result = DaytimeStress.Result(
            hours: [point(12, level: 2.1), point(13, level: 2.4), point(14, level: 2.6)],
            sustainedHigh: true, sustainedRun: 3, dayMean: 2.3, peak: point(14, level: 2.6))
        let line = AICoachEngine.daytimeStressLine(result)
        XCTAssertTrue(line!.contains("sustained HIGH for the last 3 scored hours"))
    }
}
