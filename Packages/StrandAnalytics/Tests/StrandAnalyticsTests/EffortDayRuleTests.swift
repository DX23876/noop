import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The day rule of 2026-11-25 (#2438): a day counts nothing below 50 % HRR, workout or not, and never scores
/// below the strongest of its workouts, each scored from its own readings with its time below 50 % HRR.
///
/// WHOOP keeps workout Strain and Day Strain as two computations: a light walk logged as a workout scores about
/// 4 while a day of walking without one scores about 2 (a paired wearer, 2026-11-22), and a day is below its
/// strongest workout on 1 of 368 days across two exports. Counting each workout's low-intensity time into the
/// day summed what WHOOP keeps apart.
final class EffortDayRuleTests: XCTestCase {

    // Resting 60 and maximum 160 put x % HRR at exactly 60 + x bpm.
    private let resting = 60.0
    private let maximum = 160.0
    private let t0 = 1_790_000_000

    /// Minutes at each intensity (% HRR), in order, one reading a second from `t0`.
    private func series(_ blocks: [(minutes: Int, pctHRR: Int)]) -> [HRSample] {
        var out: [HRSample] = []
        var ts = t0
        for block in blocks {
            for _ in 0 ..< block.minutes * 60 {
                out.append(HRSample(ts: ts, bpm: 60 + block.pctHRR))
                ts += 1
            }
        }
        return out
    }

    private func effort(_ hr: [HRSample], _ low: StrainScorer.LowIntensity,
                        strengthLoad: Double = 0) throws -> Double {
        try XCTUnwrap(StrainScorer.strain(hr, maxHR: maximum, restingHR: resting, lowIntensity: low,
                                          strengthLoad: strengthLoad))
    }

    private func minutes(_ from: Int, _ to: Int) -> Range<Int> { (t0 + from * 60) ..< (t0 + to * 60) }

    /// Two half-hour walks at 35 % HRR, an hour apart: the day is the stronger walk, not the two summed.
    func testTwoWalksMakeADayAsStrongAsOneOfThem() throws {
        let day = series([(30, 35), (60, 5), (30, 35)])
        let walks = [minutes(0, 30), minutes(90, 120)]
        let oneWalk = try effort(series([(30, 35)]), .counted)
        let bothWalks = try effort(series([(60, 35)]), .counted)
        XCTAssertEqual(try effort(day, .day(workouts: walks)), oneWalk, accuracy: 1e-9)
        XCTAssertLessThan(oneWalk, bothWalks)
    }

    /// Below 50 % HRR nothing counts in a day, inside a workout or not; what it reaches is the workout's own.
    func testLowIntensityInsideAWorkoutDoesNotAddToTheDay() throws {
        let day = series([(600, 25)])
        XCTAssertEqual(try effort(day, .day(workouts: [])), 0)
        let firstHour = try effort(series([(60, 25)]), .counted)
        XCTAssertEqual(try effort(day, .day(workouts: [minutes(0, 60)])), firstHour, accuracy: 1e-9)
    }

    /// Time above 50 % HRR counts wherever it is, so a day with a tempo hour outside any workout scores it.
    func testTimeAboveZoneOneCountsOutsideWorkouts() throws {
        let tempo = series([(60, 75)])
        XCTAssertEqual(try effort(tempo, .day(workouts: [])), try effort(tempo, .counted), accuracy: 1e-9)
    }

    /// When the day's own load beats every workout, the day keeps it: the floor only ever lifts.
    func testTheFloorNeverLowersADay() throws {
        let day = series([(20, 40), (120, 70)])
        let walk = [minutes(0, 20)]
        let dayAlone = try effort(day, .day(workouts: []))
        XCTAssertGreaterThan(dayAlone, try effort(series([(20, 40)]), .counted))
        XCTAssertEqual(try effort(day, .day(workouts: walk)), dayAlone, accuracy: 1e-9)
    }

    /// A workout scores from its own readings only: a span with no readings in the series floors nothing.
    func testAWorkoutOutsideTheSeriesFloorsNothing() throws {
        let day = series([(60, 25)])
        XCTAssertEqual(try effort(day, .day(workouts: [minutes(600, 660)])), 0)
    }

    /// Rated strength sessions add their load on top of whichever load the day reaches.
    func testStrengthLoadAddsOnTopOfTheFloor() throws {
        let day = series([(30, 35), (60, 5)])
        let walk = [minutes(0, 30)]
        let floored = try effort(day, .day(workouts: walk))
        let withStrength = try effort(day, .day(workouts: walk), strengthLoad: 10)
        XCTAssertEqual(withStrength, StrainScorer.effortValue(floored, addingStrengthLoad: 10), accuracy: 0.01)
        XCTAssertGreaterThan(withStrength, floored)
    }
}
