import XCTest
@testable import StrandAnalytics

final class WorkoutPersonalBestTests: XCTestCase {
    private func capture(length: Double = 1000, seconds: Double = 300) -> WorkoutRecordingTimeline {
        var timeline = WorkoutRecordingTimeline(splitLengthM: length)
        timeline.recordDistance(0, at: 0, segment: 0)
        timeline.recordDistance(length, at: seconds, segment: 0)
        return timeline
    }

    func testOnlyMeasuredFullSplitCanBeACandidate() {
        XCTAssertEqual(WorkoutPersonalBest.candidate(timeline: capture(), sport: "Running")?.seconds, 300)
        var partial = WorkoutRecordingTimeline(splitLengthM: 1000)
        partial.recordDistance(999, at: 300, segment: 0)
        XCTAssertNil(WorkoutPersonalBest.candidate(timeline: partial, sport: "Running"))
        XCTAssertNil(WorkoutPersonalBest.candidate(timeline: capture(length: 500), sport: "Running"))
    }

    func testAnyPauseOrRouteGapDisqualifiesTheWorkout() {
        var paused = capture()
        paused.beginPause(atUnixSeconds: 1000)
        paused.endPause(atUnixSeconds: 1010)
        XCTAssertNil(WorkoutPersonalBest.candidate(timeline: paused, sport: "Running"))
        var gap = capture()
        gap.interrupt()
        XCTAssertNil(WorkoutPersonalBest.candidate(timeline: gap, sport: "Running"))
    }

    func testBaselineTieDifferentSportAndDifferentLengthAreNotNewBests() {
        let current = WorkoutPersonalBest.Candidate(sport: "Running", meters: 1000, seconds: 300)
        XCTAssertNil(WorkoutPersonalBest.improvement(current: current, previous: nil))
        XCTAssertNil(WorkoutPersonalBest.improvement(current: current, previous: current))
        XCTAssertNil(WorkoutPersonalBest.improvement(current: current,
            previous: .init(sport: "Running", meters: 1000, seconds: 300.1)))
        XCTAssertNil(WorkoutPersonalBest.improvement(current: current, previous: .init(sport: "Cycling", meters: 1000, seconds: 330)))
        XCTAssertNil(WorkoutPersonalBest.improvement(current: current, previous: .init(sport: "Running", meters: 1609.344, seconds: 330)))
        XCTAssertEqual(WorkoutPersonalBest.improvement(current: current,
            previous: .init(sport: "Running", meters: 1000, seconds: 310))?.previous.seconds, 310)
    }
}
