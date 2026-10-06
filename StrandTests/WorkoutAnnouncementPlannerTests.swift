import XCTest
import WhoopProtocol
@testable import Strand

final class WorkoutAnnouncementPlannerTests: XCTestCase {
    func testDistanceModeAnnouncesEachFullKilometerOnce() {
        var planner = WorkoutAnnouncementPlanner(mode: .distance(splitMeters: 1_000))
        XCTAssertNil(planner.update(distanceMeters: 999, elapsedSeconds: 330))
        XCTAssertEqual(planner.update(distanceMeters: 1_004, elapsedSeconds: 342),
                       .split(index: 1, splits: 1, splitSeconds: 342, elapsedSeconds: 342))
        // The same kilometre is not announced twice.
        XCTAssertNil(planner.update(distanceMeters: 1_400, elapsedSeconds: 470))
        XCTAssertEqual(planner.update(distanceMeters: 2_001, elapsedSeconds: 660),
                       .split(index: 2, splits: 1, splitSeconds: 318, elapsedSeconds: 660))
    }

    func testGpsJumpOverSeveralMarksAnnouncesOnlyTheNewestAndSpreadsTheTime() {
        var planner = WorkoutAnnouncementPlanner(mode: .distance(splitMeters: 1_000))
        XCTAssertEqual(planner.update(distanceMeters: 3_050, elapsedSeconds: 900),
                       .split(index: 3, splits: 3, splitSeconds: 900, elapsedSeconds: 900))
    }

    func testNoRouteDistanceNeverAnnounces() {
        var planner = WorkoutAnnouncementPlanner(mode: .distance(splitMeters: 1_000))
        XCTAssertNil(planner.update(distanceMeters: nil, elapsedSeconds: 5_000))
    }

    func testTimeModeAnnouncesEachIntervalOfActiveTime() {
        var planner = WorkoutAnnouncementPlanner(mode: .time(intervalSeconds: 600))
        XCTAssertNil(planner.update(distanceMeters: nil, elapsedSeconds: 599))
        XCTAssertEqual(planner.update(distanceMeters: nil, elapsedSeconds: 600), .interval(elapsedSeconds: 600))
        XCTAssertNil(planner.update(distanceMeters: nil, elapsedSeconds: 900))
        XCTAssertEqual(planner.update(distanceMeters: nil, elapsedSeconds: 1_201), .interval(elapsedSeconds: 1_201))
    }

    func testAverageBpmUsesOnlySamplesSinceTheLastMark() {
        let samples = [HRSample(ts: 100, bpm: 120), HRSample(ts: 200, bpm: 150), HRSample(ts: 201, bpm: 152)]
        XCTAssertEqual(WorkoutVoiceCoach.averageBpm(samples, since: 200), 151)
        XCTAssertNil(WorkoutVoiceCoach.averageBpm(samples, since: 300))
    }

    func testSummaryWithRouteNamesDistanceTimeAndPace() {
        let english = Locale(identifier: "en_US")
        let text = WorkoutAnnouncementText.summary(elapsedSeconds: 1_680, distanceMeters: 5_200,
                                                   system: .metric, locale: english)
        XCTAssertTrue(text.hasPrefix("Workout ended."), text)
        XCTAssertTrue(text.contains("5.2 kilometers"), text)
        XCTAssertTrue(text.contains("28 minutes"), text)
        XCTAssertTrue(text.contains("Average pace 5 minutes, 23 seconds per kilometer."), text)
    }

    func testIntervalLeavesOutWhatWasNotMeasured() {
        let english = Locale(identifier: "en_US")
        let text = WorkoutAnnouncementText.interval(elapsedSeconds: 600, averageBpm: nil, effort: nil,
                                                    zoneLine: nil, locale: english)
        XCTAssertEqual(text, "Time 10 minutes.")
    }
}
