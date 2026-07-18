import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins T3.2 of Etappe T: `get_sleep_detail`'s description already promised "bed/wake times" —
/// `sleepDetailTool` never delivered them. `AICoachEngine.formatSleepDetail` is the pure core (no
/// `repo`/store reads) that was extracted so this is testable without a database, mirroring the
/// codebase's "pure core, thin I/O shell" convention (`SleepPhantomNightFallbackTests` does the same
/// for `SleepView.stubDaySession`).
final class CoachSleepDetailFormatTests: XCTestCase {

    private func day(_ dayStr: String) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90,
                    lightMin: 250, disturbances: 2, restingHr: 50, avgHrv: 60, recovery: 70,
                    strain: 10, exerciseCount: nil)
    }

    func testEmptyDaysMeansNoSleepDataRecordedYet() {
        let text = AICoachEngine.formatSleepDetail(recentDays: [], sessions: [], habitualMidsleepSec: nil)
        XCTAssertEqual(text, "No sleep data recorded yet.")
    }

    /// A session whose wake-day matches a `DailyMetric`'s day shows real clock times.
    func testMatchingSessionShowsBedAndWakeTimes() {
        let endTs = 1_780_000_000
        let startTs = endTs - 8 * 3_600
        let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(endTs)))
        let dayStr = AnalyticsEngine.dayString(endTs, offsetSec: offsetSec)
        let session = CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: 0.9, restingHr: 50,
                                         avgHrv: 60, stagesJSON: nil)

        let text = AICoachEngine.formatSleepDetail(recentDays: [day(dayStr)], sessions: [session],
                                                    habitualMidsleepSec: nil)
        XCTAssertTrue(text.contains("→"), "expected a bed→wake clock range, got:\n\(text)")
        XCTAssertFalse(text.contains("bed/wake —"))
    }

    /// A day with no matching session (no stored block for that wake-day) degrades honestly instead of
    /// showing a fabricated or stale time.
    func testDayWithoutAMatchingSessionShowsAPlaceholder() {
        let text = AICoachEngine.formatSleepDetail(recentDays: [day("2026-01-01")], sessions: [],
                                                    habitualMidsleepSec: nil)
        XCTAssertTrue(text.contains("bed/wake —"))
    }

    /// A large shift (≥20 min) from the learned habitual midsleep is called out, with the correct
    /// direction (earlier/later).
    func testLargeShiftFromHabitualMidsleepIsCalledOutWithDirection() {
        let endTs = 1_780_000_000
        let startTs = endTs - 8 * 3_600
        let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(endTs)))
        let dayStr = AnalyticsEngine.dayString(endTs, offsetSec: offsetSec)
        let session = CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: nil, restingHr: nil,
                                         avgHrv: nil, stagesJSON: nil)
        let mid = (startTs + endTs) / 2
        let localMid = (((mid + offsetSec) % 86_400) + 86_400) % 86_400
        // Habitual midsleep 30 min LATER than tonight's → tonight reads "earlier".
        let habitual = (localMid + 1_800) % 86_400

        let text = AICoachEngine.formatSleepDetail(recentDays: [day(dayStr)], sessions: [session],
                                                    habitualMidsleepSec: habitual)
        XCTAssertTrue(text.contains("~30 min earlier than the user's usual, learned midsleep"),
                     "got:\n\(text)")
    }

    /// A shift under the 20-minute threshold is noise, not signal — no line, so the coach doesn't
    /// nag over an ordinary night-to-night wobble.
    func testSmallShiftFromHabitualMidsleepStaysSilent() {
        let endTs = 1_780_000_000
        let startTs = endTs - 8 * 3_600
        let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(endTs)))
        let dayStr = AnalyticsEngine.dayString(endTs, offsetSec: offsetSec)
        let session = CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: nil, restingHr: nil,
                                         avgHrv: nil, stagesJSON: nil)
        let mid = (startTs + endTs) / 2
        let localMid = (((mid + offsetSec) % 86_400) + 86_400) % 86_400
        let habitual = (localMid + 300) % 86_400   // 5 min later

        let text = AICoachEngine.formatSleepDetail(recentDays: [day(dayStr)], sessions: [session],
                                                    habitualMidsleepSec: habitual)
        XCTAssertFalse(text.contains("usual, learned midsleep"))
    }

    /// No learned habitual value yet (cold-start) → no comparison line, never a fabricated one.
    func testNoHabitualValueMeansNoComparisonLine() {
        let text = AICoachEngine.formatSleepDetail(recentDays: [day("2026-01-01")], sessions: [],
                                                    habitualMidsleepSec: nil)
        XCTAssertFalse(text.contains("usual, learned midsleep"))
    }
}
