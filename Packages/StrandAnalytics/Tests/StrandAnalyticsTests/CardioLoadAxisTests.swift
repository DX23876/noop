import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Cardio totals must stay on ONE axis. TRIMP is additive and unbounded; Effort is its compressed
/// presentation. A history that is part measured and part legacy must therefore not add the two
/// together — the result would be a number in no unit, and it would move when a single old session
/// gained a measured trace.
final class CardioLoadAxisTests: XCTestCase {
    private func session(day: String, start: Int, trimp: Double?, effort: Double?) -> CardioSessionMetrics {
        CardioSessionMetrics(startTs: start, endTs: start + 3_600, day: day, sport: "Running",
                             source: "apple-health", modality: .foot, durationS: 3_600, distanceM: 10_000,
                             avgHr: 150, maxHr: 170, energyKcal: 600, strain: effort, steps: nil,
                             cardioLoad: trimp)
    }

    func testAMeasuredSessionNeverHasLegacyEffortAddedToIt() throws {
        let measured = session(day: "2026-09-07", start: 1_000, trimp: 120, effort: 12)
        let legacyOnly = session(day: "2026-09-08", start: 90_000, trimp: nil, effort: 11)
        let week = CardioSession.week(containing: "2026-09-07", sessions: [measured, legacyOnly])
        // 120 alone: the legacy session is unmeasured on this axis, which is missing data rather than
        // an easy session, and 120 + 11 would be neither TRIMP nor Effort.
        XCTAssertEqual(try XCTUnwrap(week.effort), 120, accuracy: 0.0001)
    }

    func testAHistoryWithNoMeasuredSessionStillTotalsItsStoredEffort() throws {
        let a = session(day: "2026-09-07", start: 1_000, trimp: nil, effort: 12)
        let b = session(day: "2026-09-08", start: 90_000, trimp: nil, effort: 8)
        let week = CardioSession.week(containing: "2026-09-07", sessions: [a, b])
        XCTAssertEqual(try XCTUnwrap(week.effort), 20, accuracy: 0.0001)
    }

    func testTheLoadTrendReadsWhicheverAxisTheHistoryIsOn() throws {
        let measured = (0..<28).map {
            session(day: AnalyticsEngine.dayString(1_700_000_000 + $0 * 86_400, offsetSec: 0),
                    start: 1_700_000_000 + $0 * 86_400, trimp: 100, effort: 10)
        }
        let asOf = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + 27 * 86_400))
        XCTAssertEqual(try XCTUnwrap(CardioSession.cardioLoadTrend(measured, asOf: asOf)).recentPerDay,
                       100, accuracy: 0.0001)

        let legacy = measured.map { session(day: $0.day, start: $0.startTs, trimp: nil, effort: 10) }
        XCTAssertEqual(try XCTUnwrap(CardioSession.cardioLoadTrend(legacy, asOf: asOf)).recentPerDay,
                       10, accuracy: 0.0001)
    }

    /// The axis rule has a consequence worth pinning: a history that is still almost all legacy cannot
    /// produce a load TREND from its one measured day. Nil is the honest answer — a comparison needs two
    /// weeks of the same measurement — where mixing the axes would have manufactured one. The weekly
    /// total, which claims no comparison, still reports what was measured.
    func testALoneMeasuredDayYieldsNoTrendRatherThanAMixedOne() throws {
        var sessions = (0..<28).map {
            session(day: AnalyticsEngine.dayString(1_700_000_000 + $0 * 86_400, offsetSec: 0),
                    start: 1_700_000_000 + $0 * 86_400, trimp: nil, effort: 10)
        }
        sessions[27] = session(day: sessions[27].day, start: sessions[27].startTs, trimp: 100, effort: 10)
        let asOf = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + 27 * 86_400))
        XCTAssertNil(CardioSession.cardioLoadTrend(sessions, asOf: asOf))
        let week = CardioSession.week(containing: sessions[27].day, sessions: sessions)
        XCTAssertEqual(try XCTUnwrap(week.effort), 100, accuracy: 0.0001)
    }
}
