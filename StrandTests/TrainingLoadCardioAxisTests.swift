import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The cardio lane's daily series. Two rules meet here: the lane is priced from measured heart rate
/// where the window has it, and a library with no measured trace at all must not silently read zero —
/// it falls back to the stored per-session Effort, on that axis alone.
final class TrainingLoadCardioAxisTests: XCTestCase {
    /// Midday UTC, so a second session two hours later still lands on the same local day.
    private static let noon = 1_699_963_200
    private let day = AnalyticsEngine.dayString(noon, offsetSec: 0)

    private func session(_ id: String, start: Int = noon, strain: Double?,
                         length: Int = 3_600) -> UnifiedTrainingSession {
        let row = WorkoutRow(startTs: start, endTs: start + length, sport: "Cycling",
                             source: "apple-health", durationS: Double(length), energyKcal: nil,
                             avgHr: 130, maxHr: 150, strain: strain, distanceM: nil,
                             zonesJSON: nil, notes: nil, steps: nil)
        return UnifiedTrainingSession(
            id: id, kind: .endurance, row: row,
            components: [TrainingSessionComponent(id: id, row: row, metadata: nil)],
            fusionOrigin: "automatic")
    }

    private func measured(_ id: String, trimp: Double) -> TrainingCardioLoad {
        TrainingCardioLoad(sessionId: id, trimp: trimp, effort: 12, source: .noopBand,
                           coveredMinutes: 60, possibleMinutes: 60)
    }

    func testAMeasuredWindowIsPricedInTrimp() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: 12)], loads: ["a": measured("a", trimp: 130)],
            duplicates: [], tzOffsetSeconds: 0)
        XCTAssertTrue(result.measured)
        XCTAssertEqual(result.byDay[day], 130)
    }

    /// The case every demo run and every strapless library hits: no session has a usable trace. Reading
    /// zero here would tell the wearer they did nothing, while the Cardio screen reports the same week
    /// from the very same stored figures.
    func testALibraryWithNoMeasuredTraceFallsBackToStoredEffort() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: 12),
                       session("b", start: Self.noon + 7_200, strain: 8)],
            loads: [:], duplicates: [], tzOffsetSeconds: 0)
        XCTAssertFalse(result.measured)
        XCTAssertEqual(result.byDay[day], 20)
    }

    /// Once anything is measured the lane is on the TRIMP axis, and an unmeasured session is missing
    /// data rather than an easy one. Adding its stored Effort would total two different units.
    func testStoredEffortIsNeverAddedToMeasuredTrimp() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: 12),
                       session("b", start: Self.noon + 7_200, strain: 8)],
            loads: ["a": measured("a", trimp: 130)], duplicates: [], tzOffsetSeconds: 0)
        XCTAssertTrue(result.measured)
        XCTAssertEqual(result.byDay[day], 130)
    }

    /// A suspected duplicate stays visible until the wearer rules on it, but it describes minutes the
    /// other record already described — on the fallback axis too.
    func testADuplicateAwaitingReviewIsCountedOnce() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: 12),
                       session("twin", start: Self.noon + 300, strain: 11)],
            loads: [:], duplicates: ["twin"], tzOffsetSeconds: 0)
        XCTAssertEqual(result.byDay[day], 12)
    }

    /// An hour of training that carries no usable figure adds nothing to the day — and says so, rather
    /// than letting the day pass for a rest day. The comparison then leaves that day out entirely.
    func testASessionWithNeitherFigureLeavesItsDayUnknown() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: nil)], loads: [:], duplicates: [], tzOffsetSeconds: 0)
        XCTAssertFalse(result.measured)
        XCTAssertNil(result.byDay[day])
        XCTAssertEqual(result.unknownDays, [day])
    }

    /// A session too short to have been priced was never going to be measured, so its day is ordinary.
    /// Treating it as a gap would drop a normal day out of the wearer's baseline.
    func testASessionBelowThePricingThresholdDoesNotMakeItsDayUnknown() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: nil, length: 300)],
            loads: [:], duplicates: [], tzOffsetSeconds: 0)
        XCTAssertTrue(result.unknownDays.isEmpty)
    }

    /// One priced session covers the day: what we know outweighs the record we could not price, and the
    /// day keeps its measured figure rather than vanishing from the comparison.
    func testADayThatAlsoHoldsAPricedSessionIsNotUnknown() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: 12),
                       session("b", start: Self.noon + 7_200, strain: nil)],
            loads: ["a": measured("a", trimp: 130)], duplicates: [], tzOffsetSeconds: 0)
        XCTAssertEqual(result.byDay[day], 130)
        XCTAssertTrue(result.unknownDays.isEmpty)
    }

    /// A duplicate awaiting review is skipped on purpose, not for want of data. Counting it as a gap
    /// would let an unresolved twin erase a day the other record described perfectly well.
    func testADuplicateAwaitingReviewIsNotAGapInTheData() {
        let result = TrainingLoadModel.cardioDailyLoad(
            sessions: [session("a", strain: 12),
                       session("twin", start: Self.noon + 300, strain: nil)],
            loads: [:], duplicates: ["twin"], tzOffsetSeconds: 0)
        XCTAssertEqual(result.byDay[day], 12)
        XCTAssertTrue(result.unknownDays.isEmpty)
    }
}
