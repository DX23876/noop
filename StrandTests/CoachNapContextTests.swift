import XCTest
@testable import Strand
import WhoopStore

/// The naps block the Coach reads: which blocks count as naps, and what the line says.
final class CoachNapContextTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-30 00:00 UTC
    private let midnight = 1_793_318_400

    private func block(_ start: Int, _ end: Int, stages: String? = "[]") -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 50, avgHrv: 60, stagesJSON: stages)
    }

    private func dayKey(_ ts: Int) -> String {
        let f = DateFormatter()
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    func testBlocksOutsideTheMainNightAreNapsAndNewestComesFirst() {
        let night = block(midnight - 7 * 3600, midnight + 1 * 3600)                       // 17:00–01:00 UTC
        let nap = block(midnight + 14 * 3600, midnight + 14 * 3600 + 30 * 60,
                        stages: #"{"light": 20, "deep": 5, "rem": 0, "awake": 5}"#)       // 14:00–14:30
        let earlierNight = block(midnight - 86_400 - 7 * 3600, midnight - 86_400 + 1 * 3600)
        let earlierNap = block(midnight - 86_400 + 13 * 3600, midnight - 86_400 + 14 * 3600, stages: nil)
        let naps = CoachNapContext.naps(dayGroups: [[night, nap], [earlierNight, earlierNap]],
                                        habitualMidsleepSec: nil, dayKey: dayKey)
        XCTAssertEqual(naps.count, 2)
        XCTAssertEqual(naps[0].day, "2026-10-30")
        XCTAssertEqual(naps[0].asleepMin, 25)
        XCTAssertNil(naps[1].asleepMin, "a stage-less block reports no asleep minutes")
    }

    func testADayWithOneBlockHasANightAndNoNap() {
        // A lone afternoon block is that day's main sleep, exactly as the Sleep tab files it.
        let lone = block(midnight + 13 * 3600, midnight + 14 * 3600)
        XCTAssertTrue(CoachNapContext.naps(dayGroups: [[lone]], habitualMidsleepSec: nil, dayKey: dayKey).isEmpty)
    }

    func testSummaryCreditsTheNightPlusNapsAndStaysSilentWithoutNaps() {
        XCTAssertEqual(CoachNapContext.summary(naps: [], mainSleepMinByDay: ["2026-10-30": 400], zone: utc), "")
        let nap = CoachNapContext.Nap(day: "2026-10-30", startTs: midnight + 14 * 3600,
                                      endTs: midnight + 14 * 3600 + 30 * 60, asleepMin: 25)
        let text = CoachNapContext.summary(naps: [nap], mainSleepMinByDay: ["2026-10-30": 420], zone: utc)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("NAPS ("))
        XCTAssertEqual(lines[1], "  2026-10-30: 14:00–14:30 (25 min asleep); night 7.0h + naps 0.4h = 7.4h credited")
    }

    func testSummaryNamesAnUnscoredNight() {
        let nap = CoachNapContext.Nap(day: "2026-10-29", startTs: midnight - 86_400 + 13 * 3600,
                                      endTs: midnight - 86_400 + 14 * 3600, asleepMin: 50)
        let text = CoachNapContext.summary(naps: [nap], mainSleepMinByDay: [:], zone: utc)
        XCTAssertTrue(text.hasSuffix("; night not scored, naps 0.8h"))
    }
}
