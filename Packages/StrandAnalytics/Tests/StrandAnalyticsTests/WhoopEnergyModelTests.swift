import XCTest
@testable import StrandAnalytics

final class WhoopEnergyModelTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")

    func testEvidenceSecondsAndEnergyArePartitionedWithoutDoubleCounting() throws {
        let rows = [
            WhoopEnergyBucket(start: 0, averageHR: 145, isWorkout: true),
            WhoopEnergyBucket(start: 300, steps: 500, distanceM: 420),
            WhoopEnergyBucket(start: 600),
            WhoopEnergyBucket(start: 900, averageHR: 130, isOffWrist: true),
        ]
        let value = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: rows, profile: profile, restingHR: 55, maxHR: 185))
        XCTAssertEqual(value.observedSeconds, 300)
        XCTAssertEqual(value.inferredSeconds, 300)
        XCTAssertEqual(value.modeledSeconds, 600)
        XCTAssertEqual(value.buckets.count, 4)
        XCTAssertEqual(value.totalKcal, value.buckets.reduce(0) { $0 + $1.kcal }, accuracy: 0.001)
        XCTAssertEqual(value.coverageFraction, 0.25, accuracy: 0.001)
    }

    func testSleepAndOffWristNeverUseElevatedHR() throws {
        let sleeping = WhoopEnergyBucket(start: 0, averageHR: 180, isSleep: true)
        let ordinary = WhoopEnergyBucket(start: 300, averageHR: 180, isWorkout: true)
        let result = try XCTUnwrap(WhoopEnergyModel.estimate(
            buckets: [sleeping, ordinary], profile: profile, restingHR: 55, maxHR: 185))
        XCTAssertEqual(result.buckets[0].evidence, .modeled)
        XCTAssertEqual(result.buckets[1].evidence, .observed)
        XCTAssertGreaterThan(result.buckets[1].kcal, result.buckets[0].kcal)
    }

    func testInvalidBucketsAndProfileDoNotInventEnergy() {
        XCTAssertNil(WhoopEnergyModel.estimate(
            buckets: [.init(start: 0)],
            profile: .init(weightKg: 0, heightCm: 0, age: 0), restingHR: nil, maxHR: nil))
        XCTAssertNil(WhoopEnergyModel.estimate(
            buckets: [.init(start: 0, durationSeconds: 0)],
            profile: profile, restingHR: nil, maxHR: nil))
    }

    func testCausalWeightNeverReadsFutureAndManualWinsSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = 2_000_000_000
        let observations = [
            CausalWeightObservation(timestamp: day, weightKg: 80, source: .health),
            CausalWeightObservation(timestamp: day + 60, weightKg: 79, source: .manual),
            CausalWeightObservation(timestamp: day + 86_400, weightKg: 60, source: .manual),
        ]
        let sameDay = CausalWeightResolver.weight(
            at: day + 3_600, observations: observations, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(sameDay), 79, accuracy: 0.001)
    }

    func testCausalWeightExpiresAfterNinetyDays() {
        let row = CausalWeightObservation(timestamp: 1_000_000, weightKg: 80, source: .manual)
        XCTAssertNil(CausalWeightResolver.weight(
            at: 1_000_000 + 91 * 86_400, observations: [row]))
    }
}
