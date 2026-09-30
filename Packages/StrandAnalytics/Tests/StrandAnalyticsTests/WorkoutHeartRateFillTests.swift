import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Pins which heart rate describes an Apple Health workout NOOP fills: the band when it covers the window,
/// else the watch's minutes, never both; the cardio load's coverage rule; and a resting rate that is the
/// day's own or a nearby Watch reading, never a stale carry.
final class WorkoutHeartRateFillTests: XCTestCase {

    private let start = 1_790_000_000

    private func band(minutes: Int, bpm: Int = 130, from offset: Int = 0) -> [HRSample] {
        (0..<(minutes * 60)).map { HRSample(ts: start + offset + $0, bpm: bpm) }
    }

    private func watch(minutes: Int, bpm: Double = 120) -> [(start: Int, bpm: Double)] {
        (0..<minutes).map { (start: start + $0 * 60, bpm: bpm + Double($0 % 5)) }
    }

    private func resolve(band: [HRSample], watch: [(start: Int, bpm: Double)], minutes: Int = 30,
                         resting: Double? = 60) -> WorkoutHeartRateFill.Result? {
        WorkoutHeartRateFill.resolve(band: band, watchMinutes: watch, start: start, end: start + minutes * 60,
                                     maxHR: 190, restingHR: resting, method: .edwards, sex: "male")
    }

    func testBandWinsWhenItCoversTheWindow() throws {
        let result = try XCTUnwrap(resolve(band: band(minutes: 30), watch: watch(minutes: 30)))
        XCTAssertEqual(result.source, .band)
        XCTAssertEqual(result.averageHR, 130)
        XCTAssertEqual(result.maxHR, 130)
        XCTAssertNotNil(result.strain)
    }

    /// A band worn for half the walk does not describe it; the watch's full trace does. Never stitched.
    func testWatchStandsInWhenTheBandCoversTooLittle() throws {
        let result = try XCTUnwrap(resolve(band: band(minutes: 15), watch: watch(minutes: 30)))
        XCTAssertEqual(result.source, .watch)
        XCTAssertEqual(result.maxHR, 124, "the highest minute, not a beat")
        XCTAssertEqual(result.averageHR, 122)
        XCTAssertEqual(result.coveredMinutes, 30)
    }

    func testNothingWhenNeitherTraceCovers() {
        XCTAssertNil(resolve(band: band(minutes: 15), watch: watch(minutes: 15)))
        // Ten minutes is the floor even when that is all of a short session.
        XCTAssertNil(resolve(band: band(minutes: 9), watch: [], minutes: 9))
        XCTAssertNotNil(resolve(band: band(minutes: 10), watch: [], minutes: 10))
    }

    /// Without the day's resting rate the averages still stand, but Effort is not scored against a default.
    func testNoRestingRateMeansNoEffort() throws {
        let result = try XCTUnwrap(resolve(band: band(minutes: 30), watch: [], resting: nil))
        XCTAssertNil(result.strain)
        XCTAssertEqual(result.averageHR, 130)
    }

    func testCoverageRuleIsTheCardioLoadsOne() {
        XCTAssertEqual(WorkoutHeartRateFill.minimumCoveredMinutes, 10)
        XCTAssertEqual(WorkoutHeartRateFill.minimumCoverage, 0.70)
        let trace = WorkoutHeartRateFill.minuteTrace([(start: start, bpm: 100), (start: start + 60, bpm: .nan)])
        XCTAssertEqual(trace.map(\.ts), [start, start + 30])
    }

    func testRestingRateIsTheDaysOwnElseANearbyWatchReading() {
        let own = ["2024-03-10": 58.0]
        let apple = ["2024-03-08": 64.0, "2024-03-14": 70.0, "2024-03-20": 66.0]
        XCTAssertEqual(WorkoutHeartRateFill.restingHR(on: "2024-03-10", own: own, apple: apple), 58)
        XCTAssertEqual(WorkoutHeartRateFill.restingHR(on: "2024-03-11", own: own, apple: apple), 64,
                       "own rates are never carried; at equal distance the earlier Watch reading wins")
        XCTAssertEqual(WorkoutHeartRateFill.restingHR(on: "2024-03-13", own: own, apple: apple), 70,
                       "the nearest Watch reading within three days, even when it is later")
        XCTAssertEqual(WorkoutHeartRateFill.restingHR(on: "2024-03-09", own: own, apple: apple), 64)
        XCTAssertNil(WorkoutHeartRateFill.restingHR(on: "2024-03-17", own: [:], apple: ["2024-03-13": 60]))
    }

    func testACarriedRestingRateIsNeverOlderThanTwoWeeks() {
        let byDay = ["2026-09-01": 60.0, "2026-09-20": 55.0]
        XCTAssertEqual(WorkoutHeartRateFill.carriedRestingHR(on: "2026-09-20", in: byDay), 55)
        XCTAssertEqual(WorkoutHeartRateFill.carriedRestingHR(on: "2026-09-15", in: byDay), 60)   // 14 days
        XCTAssertNil(WorkoutHeartRateFill.carriedRestingHR(on: "2026-09-16", in: byDay))         // 15 days
    }
}
