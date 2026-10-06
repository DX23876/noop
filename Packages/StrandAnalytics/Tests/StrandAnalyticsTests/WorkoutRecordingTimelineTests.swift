import XCTest
@testable import StrandAnalytics

final class WorkoutRecordingTimelineTests: XCTestCase {
    func testCurrentZoneStreakUsesOneClockAndResetsOnDropoutOrZoneChange() {
        var timeline = WorkoutRecordingTimeline(zoneUpperBPM: [120, 140, 160, 180, 200])
        timeline.recordHeartRate(125, at: 0)
        timeline.recordHeartRate(126, at: 5)
        XCTAssertEqual(timeline.currentZoneSeconds(at: 8), 8)
        XCTAssertEqual(timeline.currentZoneSeconds(at: 11), 0)
        timeline.recordHeartRate(125, at: 20)
        XCTAssertEqual(timeline.currentZoneSeconds(at: 22), 2)
        timeline.recordHeartRate(145, at: 23)
        XCTAssertEqual(timeline.currentZoneSeconds(at: 24), 1)
        XCTAssertEqual(timeline.currentZoneSeconds(at: 22), 0)
    }
    func testPauseHistorySurvivesRestoreWithoutResumingAManualPause() throws {
        var timeline = WorkoutRecordingTimeline()
        timeline.beginPause(atUnixSeconds: 100)
        timeline.beginPause(atUnixSeconds: 101)
        XCTAssertEqual(timeline.pauses?.count, 1)
        var restored = try JSONDecoder().decode(WorkoutRecordingTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertNil(restored.pauses?.last?.endUnixSeconds)
        restored.endPause(atUnixSeconds: 130)
        restored.beginPause(atUnixSeconds: 150)
        restored.endPause(atUnixSeconds: 170)
        XCTAssertEqual(restored.pauses?.map { ($0.endUnixSeconds ?? 0) - $0.startUnixSeconds }, [30, 20])
        XCTAssertTrue(restored.isValid)
    }
    func testRollingPaceRequiresFiveSecondsAndExpires() {
        var timeline = WorkoutRecordingTimeline(splitLengthM: 1000)
        for second in 0...40 { timeline.recordDistance(Double(second * 4), at: Double(second), segment: 0) }
        XCTAssertEqual(timeline.currentSpeedMps(at: 40, lastFixAge: 0) ?? 0, 4, accuracy: 0.0001)
        XCTAssertNil(timeline.currentSpeedMps(at: 46, lastFixAge: 6))
        var short = WorkoutRecordingTimeline(splitLengthM: 1000)
        short.recordDistance(0, at: 0, segment: 0)
        short.recordDistance(8, at: 2, segment: 0)
        XCTAssertNil(short.currentSpeedMps(at: 2, lastFixAge: 0))
    }

    func testSplitCrossingIsInterpolatedAndTailIsPartial() {
        var timeline = WorkoutRecordingTimeline(splitLengthM: 1000)
        timeline.recordDistance(0, at: 0, segment: 0)
        timeline.recordDistance(900, at: 90, segment: 0)
        timeline.recordDistance(1100, at: 110, segment: 0)
        XCTAssertEqual(timeline.splits.first?.duration, 100)
        let tail = timeline.sections(at: 120).last
        XCTAssertEqual(tail?.distanceM, 100)
        XCTAssertEqual(tail?.duration, 20)
        XCTAssertEqual(tail?.partial, true)
    }

    func testManualPauseExcludesMissingLegAndResetsCurrentSpeed() {
        var timeline = WorkoutRecordingTimeline(splitLengthM: 1000)
        timeline.recordDistance(0, at: 0, segment: 0)
        timeline.recordDistance(900, at: 90, segment: 0)
        timeline.pause()
        XCTAssertNil(timeline.currentSpeedMps(at: 90, lastFixAge: 0))
        timeline.recordDistance(900, at: 91, segment: 1)
        timeline.recordDistance(1100, at: 111, segment: 1)
        XCTAssertEqual(timeline.splits.count, 1)
        XCTAssertEqual(timeline.splits[0].endSeconds, 101)
        XCTAssertFalse(timeline.splits[0].interrupted)
    }

    func testMeasurementGapNeverGetsInterpolatedIntoASplit() {
        var timeline = WorkoutRecordingTimeline(splitLengthM: 1000)
        timeline.recordDistance(0, at: 0, segment: 0)
        timeline.recordDistance(900, at: 90, segment: 0)
        timeline.recordDistance(900, at: 120, segment: 1)
        timeline.recordDistance(1100, at: 140, segment: 1)
        XCTAssertTrue(timeline.splits[0].interrupted)
        XCTAssertNil(timeline.splits[0].speedMps)
        XCTAssertEqual(timeline.splits[0].endSeconds, 130)
    }

    func testTimeOnlyManualLapsAreIndependentOfDistance() {
        var timeline = WorkoutRecordingTimeline()
        XCTAssertTrue(timeline.markLap(at: 60))
        XCTAssertFalse(timeline.markLap(at: 60))
        XCTAssertTrue(timeline.markLap(at: 120))
        XCTAssertEqual(timeline.laps.map(\.duration), [60, 60])
        XCTAssertTrue(timeline.laps.allSatisfy { $0.distanceM == nil })
        XCTAssertEqual(timeline.manualSections(at: 130).last?.duration, 10)
        XCTAssertTrue(timeline.sections(at: 130).isEmpty)
    }

    func testZonesKeepOriginalBoundsAndDoNotCreditDropoutsOrBelowZoneOne() throws {
        var timeline = WorkoutRecordingTimeline(zoneUpperBPM: [120, 140, 160, 180, 200],
                                                zoneLowerBPM: [100, 120, 140, 160, 180])
        timeline.recordHeartRate(90, at: 0)
        timeline.recordHeartRate(120, at: 5)
        timeline.recordHeartRate(170, at: 30)
        let restored = try JSONDecoder().decode(WorkoutRecordingTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(restored.zoneSeconds(at: 60), [0, 10, 0, 10, 0])
        XCTAssertEqual(restored.zoneUpperBPM, [120, 140, 160, 180, 200])
    }

    func testMileSplitsAndManualLapsDoNotResetEachOther() {
        var timeline = WorkoutRecordingTimeline(splitLengthM: 1609.344)
        timeline.recordDistance(0, at: 0, segment: 0)
        timeline.recordDistance(800, at: 80, segment: 0)
        timeline.markLap(at: 80)
        timeline.recordDistance(1700, at: 170, segment: 0)
        XCTAssertEqual(timeline.splits.count, 1)
        XCTAssertEqual(timeline.splits[0].distanceM, 1609.344)
        XCTAssertEqual(timeline.manualSections(at: 170).last?.distanceM, 900)
    }

    func testInvalidAndOutOfOrderEvidenceIsIgnored() {
        var timeline = WorkoutRecordingTimeline(splitLengthM: .nan, zoneUpperBPM: [1, 2])
        timeline.recordDistance(0, at: 10, segment: 0)
        timeline.recordDistance(100, at: 5, segment: 0)
        timeline.recordDistance(.infinity, at: 20, segment: 0)
        timeline.recordHeartRate(301, at: 0)
        XCTAssertNil(timeline.splitLengthM)
        XCTAssertEqual(timeline.distanceM, 0)
        XCTAssertTrue(timeline.readings.isEmpty)
        XCTAssertTrue(timeline.zoneSeconds(at: 20).isEmpty)
    }
}
