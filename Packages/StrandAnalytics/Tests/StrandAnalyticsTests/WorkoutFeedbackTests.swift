import XCTest
@testable import StrandAnalytics

final class WorkoutFeedbackTests: XCTestCase {
    func testSharedFreshnessResolverRejectsPauseStaleFutureAndNonFiniteReadings() {
        XCTAssertEqual(WorkoutFreshReading.resolve(148, observedAt: 100, now: 105, paused: false), 148)
        XCTAssertNil(WorkoutFreshReading.resolve(148, observedAt: 100, now: 106, paused: false))
        XCTAssertNil(WorkoutFreshReading.resolve(148, observedAt: 110, now: 105, paused: false))
        XCTAssertNil(WorkoutFreshReading.resolve(148, observedAt: 100, now: 101, paused: true))
        XCTAssertNil(WorkoutFreshReading.resolve(.nan, observedAt: 100, now: 101, paused: false))
    }
    func testRangeRequiresTenContinuousFreshSecondsAndSixtySecondCooldown() {
        var engine = WorkoutRangeAlertEngine()
        for tick in 0..<10 { XCTAssertNil(engine.update(value: 160, range: 120...150, now: Double(tick), paused: false)) }
        XCTAssertEqual(engine.update(value: 160, range: 120...150, now: 10, paused: false), .above)
        for tick in 11..<70 { XCTAssertNil(engine.update(value: 160, range: 120...150, now: Double(tick), paused: false)) }
        XCTAssertEqual(engine.update(value: 160, range: 120...150, now: 70, paused: false), .above)
    }

    func testMissingReadingPauseAndRangeChangeResetDwell() {
        var engine = WorkoutRangeAlertEngine()
        for tick in 0..<10 { _ = engine.update(value: 160, range: 120...150, now: Double(tick), paused: false) }
        XCTAssertNil(engine.update(value: nil, range: 120...150, now: 10, paused: false))
        XCTAssertNil(engine.update(value: 160, range: 120...150, now: 11, paused: false))
        XCTAssertNil(engine.update(value: 160, range: 120...150, now: 12, paused: true))
        XCTAssertNil(engine.update(value: 160, range: 100...140, now: 13, paused: false))
        XCTAssertNil(engine.update(value: 160, range: 100...140, now: 23, paused: false)) // ten-second sampling gap
    }

    func testAutoPauseNeverResumesAManualPause() {
        var engine = WorkoutAutoPauseEngine()
        for tick in 0...20 {
            XCTAssertNil(engine.update(now: Double(tick), stationary: false, moving: true,
                                       enabled: true, paused: true, automaticallyPaused: false))
        }
    }

    func testAutoPauseFiveSecondsAndResumeThreeSeconds() {
        var engine = WorkoutAutoPauseEngine()
        for tick in 0..<5 {
            XCTAssertNil(engine.update(now: Double(tick), stationary: true, moving: false,
                                       enabled: true, paused: false, automaticallyPaused: false))
        }
        XCTAssertEqual(engine.update(now: 5, stationary: true, moving: false,
                                     enabled: true, paused: false, automaticallyPaused: false), .pause)
        for tick in 6..<9 {
            XCTAssertNil(engine.update(now: Double(tick), stationary: false, moving: true,
                                       enabled: true, paused: true, automaticallyPaused: true))
        }
        XCTAssertEqual(engine.update(now: 9, stationary: false, moving: true,
                                     enabled: true, paused: true, automaticallyPaused: true), .resume)
    }

    func testAutoPauseUnknownMotionAndGapsDoNotProduceDecisions() {
        var engine = WorkoutAutoPauseEngine()
        _ = engine.update(now: 0, stationary: true, moving: false, enabled: true, paused: false, automaticallyPaused: false)
        XCTAssertNil(engine.update(now: 10, stationary: true, moving: false, enabled: true, paused: false, automaticallyPaused: false))
        XCTAssertNil(engine.update(now: 11, stationary: nil, moving: false, enabled: true, paused: false, automaticallyPaused: false))
        XCTAssertNil(engine.update(now: 12, stationary: true, moving: false, enabled: false, paused: false, automaticallyPaused: false))
    }

    func testFeedbackFallbackChangesAndNoBacklog() {
        var schedule = WorkoutFeedbackSchedule()
        schedule.prime(distance: 0, seconds: 0, everyMeters: 1000, everySeconds: 300)
        XCTAssertNil(schedule.update(distance: 999, seconds: 299, distanceFresh: true, everyMeters: 1000, everySeconds: 300, paused: false))
        XCTAssertEqual(schedule.update(distance: 1000, seconds: 300, distanceFresh: true, everyMeters: 1000, everySeconds: 300, paused: false), .distance(1000))
        XCTAssertEqual(schedule.update(distance: 1000, seconds: 600, distanceFresh: false, everyMeters: 1000, everySeconds: 300, paused: false), .time)
        XCTAssertNil(schedule.update(distance: 1500, seconds: 601, distanceFresh: true, everyMeters: 500, everySeconds: 300, paused: false))
        XCTAssertNil(schedule.update(distance: 2000, seconds: 650, distanceFresh: true, everyMeters: 500, everySeconds: 300, paused: true))
        XCTAssertEqual(schedule.update(distance: 2000, seconds: 650, distanceFresh: true, everyMeters: 500, everySeconds: 300, paused: false), .distance(2000))
    }
}
