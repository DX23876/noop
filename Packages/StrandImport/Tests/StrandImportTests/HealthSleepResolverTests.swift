import XCTest
@testable import StrandImport

final class HealthSleepResolverTests: XCTestCase {
    private func sample(_ start: Double, _ end: Double, _ stage: HealthSleepResolver.Stage,
                        source: String = "watch", watch: Bool = true) -> HealthSleepResolver.Sample {
        .init(start: Date(timeIntervalSince1970: start * 60), end: Date(timeIntervalSince1970: end * 60),
              source: source, isWatch: watch, stage: stage)
    }
    func testMirroredNightsUseOneSourceAndIgnoreInBed() throws {
        let nights = HealthSleepResolver.resolve([
            sample(0, 480, .inBed), sample(0, 480, .unspecified),
            sample(0, 120, .deep), sample(120, 420, .core), sample(420, 480, .rem),
            sample(0, 480, .unspecified, source: "mirror", watch: false)])
        let night = try XCTUnwrap(nights.first)
        XCTAssertEqual(nights.count, 1); XCTAssertEqual(night.asleep, 480)
        XCTAssertEqual(night.deep, 120); XCTAssertEqual(night.rem, 60); XCTAssertEqual(night.core, 300)
    }
    func testMidnightBelongsToOneWakeDayAndNapStaysSeparate() throws {
        let nights = HealthSleepResolver.resolve([sample(1380, 1500, .deep), sample(1500, 1860, .core), sample(2280, 2310, .core)])
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[0].asleep, 480)
        XCTAssertEqual(nights[0].wake.timeIntervalSince1970, 1860 * 60)
        XCTAssertEqual(nights[1].asleep, 30)
    }
    func testDuplicateAndConflictingStagesDoNotAddElapsedTimeTwice() throws {
        let nights = HealthSleepResolver.resolve([sample(0, 120, .core), sample(0, 120, .core), sample(30, 60, .awake), sample(60, 90, .deep)])
        let night = try XCTUnwrap(nights.first)
        XCTAssertEqual(night.asleep, 90); XCTAssertEqual(night.deep, 30); XCTAssertEqual(night.core, 60)
    }
    func testSourceChoiceIsStableUnderInputOrder() {
        let samples = [sample(0, 120, .core, source: "A", watch: false), sample(0, 60, .deep, source: "B", watch: false)]
        XCTAssertEqual(HealthSleepResolver.resolve(samples), HealthSleepResolver.resolve(samples.reversed()))
    }
    func testLowPriorityAllDayBlockCannotBridgeWatchNightAndNap() {
        for stage in [HealthSleepResolver.Stage.unspecified, .awake] {
            let nights = HealthSleepResolver.resolve([sample(0, 480, .core), sample(960, 990, .core),
                sample(0, 1440, stage, source: "mirror", watch: false)])
            XCTAssertEqual(nights.count, 2)
            XCTAssertEqual(nights.map(\.asleep), [480, 30])
        }
    }
    func testInBedAloneDoesNotInventSleep() {
        XCTAssertTrue(HealthSleepResolver.resolve([sample(0, 480, .inBed)]).isEmpty)
    }
}
