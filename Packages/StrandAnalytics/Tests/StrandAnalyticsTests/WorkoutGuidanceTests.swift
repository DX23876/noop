import XCTest
@testable import StrandAnalytics

final class WorkoutGuidanceTests: XCTestCase {
    func testTimedPhasesUseActiveTimeAndDoNotAutoEndWorkout() {
        var plan = WorkoutGuidance(phases: [.init(kind: .warmup, seconds: 60), .init(kind: .work, seconds: 30)])
        XCTAssertFalse(plan.update(seconds: 60, meters: 0, distanceFresh: false, paused: true))
        XCTAssertTrue(plan.update(seconds: 60, meters: 0, distanceFresh: false, paused: false))
        XCTAssertEqual(plan.current?.kind, .work)
        XCTAssertEqual(plan.remaining(seconds: 70, meters: 0), 20)
        XCTAssertTrue(plan.update(seconds: 90, meters: 0, distanceFresh: false, paused: false))
        XCTAssertTrue(plan.isComplete)
        XCTAssertNil(plan.current)
        XCTAssertEqual(plan.transitions.map(\.activeSeconds), [60, 90])
    }

    func testDistancePhaseStallsOnMissingGps() {
        var plan = WorkoutGuidance(phases: [.init(kind: .work, meters: 400), .init(kind: .recovery, seconds: 60)])
        XCTAssertFalse(plan.update(seconds: 200, meters: 400, distanceFresh: false, paused: false))
        XCTAssertEqual(plan.index, 0)
        XCTAssertTrue(plan.update(seconds: 210, meters: 401, distanceFresh: true, paused: false))
        XCTAssertEqual(plan.current?.kind, .recovery)
        XCTAssertEqual(plan.phaseStartedSeconds, 210)
    }

    func testRestoreIsAnIndependentCopyAndSkipIsRecorded() throws {
        let template = WorkoutGuidance(phases: [.init(kind: .work, seconds: 120), .init(kind: .cooldown, seconds: 60)])
        var session = try JSONDecoder().decode(WorkoutGuidance.self, from: JSONEncoder().encode(template))
        XCTAssertTrue(session.skip(seconds: 20, meters: 40))
        XCTAssertTrue(session.transitions[0].skipped)
        XCTAssertEqual(template.index, 0)
        XCTAssertEqual(session.index, 1)
        XCTAssertTrue(session.isValid)
    }

    func testInvalidPlansAreInert() {
        for phase in [WorkoutGuidance.Phase(kind: .work), .init(kind: .work, seconds: -1), .init(kind: .work, meters: .infinity), .init(kind: .work, seconds: 30, meters: 100)] {
            var plan = WorkoutGuidance(phases: [phase])
            XCTAssertFalse(plan.isValid)
            XCTAssertFalse(plan.update(seconds: 100, meters: 1000, distanceFresh: true, paused: false))
        }
    }

    func testPacerUsesActiveTimeAndRejectsStaleOrInterruptedGps() {
        let pacer = WorkoutPacer(meters: 5000, seconds: 1500)
        XCTAssertEqual(pacer.aheadSeconds(distanceM: 1000, activeSeconds: 280, fresh: true, uninterrupted: true), 20)
        XCTAssertEqual(pacer.aheadSeconds(distanceM: 1000, activeSeconds: 320, fresh: true, uninterrupted: true), -20)
        XCTAssertNil(pacer.aheadSeconds(distanceM: 1000, activeSeconds: 320, fresh: false, uninterrupted: true))
        XCTAssertNil(pacer.aheadSeconds(distanceM: 1000, activeSeconds: 320, fresh: true, uninterrupted: false))
    }

    func testEditingOnlyFuturePhasesPreservesClockAndRejectsRacedTransition() throws {
        var plan = WorkoutGuidance(phases: [.init(kind: .work, seconds: 60), .init(kind: .recovery, seconds: 60)])
        let current = try XCTUnwrap(plan.current)
        XCTAssertTrue(plan.replaceUpcoming(expectedCurrentID: current.id, phases: [.init(kind: .cooldown, seconds: 90)]))
        XCTAssertEqual(plan.current, current)
        XCTAssertEqual(plan.phaseStartedSeconds, 0)
        XCTAssertTrue(plan.update(seconds: 60, meters: 100, distanceFresh: true, paused: false))
        XCTAssertFalse(plan.replaceUpcoming(expectedCurrentID: current.id, phases: []))
        XCTAssertEqual(plan.current?.kind, .cooldown)
    }

    func testHealthEventProjectionUsesOriginalPauseAndActiveClock() {
        var timeline = WorkoutRecordingTimeline()
        timeline.startUnixSeconds = 1000
        timeline.beginPause(atUnixSeconds: 1030)
        timeline.endPause(atUnixSeconds: 1050)
        _ = timeline.markLap(at: 60)
        let events = WorkoutRecordingEvents.make(timeline: timeline, fallbackStart: 1000, end: 1100, activeSeconds: 80)
        XCTAssertTrue(events.contains { $0.kind == .pause && $0.start == 1030 })
        XCTAssertTrue(events.contains { $0.kind == .resume && $0.start == 1050 })
        XCTAssertTrue(events.contains { $0.kind == .lap && $0.start == 1000 && $0.end == 1080 })
    }

    func testEndingWhilePausedDoesNotFabricateAResumeEvent() {
        var timeline = WorkoutRecordingTimeline()
        timeline.startUnixSeconds = 1000
        timeline.beginPause(atUnixSeconds: 1030)
        timeline.endPause(atUnixSeconds: 1100)
        let events = WorkoutRecordingEvents.make(timeline: timeline, fallbackStart: 1000, end: 1100, activeSeconds: 30)
        XCTAssertTrue(events.contains { $0.kind == .pause && $0.start == 1030 })
        XCTAssertFalse(events.contains { $0.kind == .resume })
    }

    func testPhaseHistoryKeepsSkipsAndMeasuredValuesNotFutureTargets() {
        var plan = WorkoutGuidance(phases: [.init(kind: .warmup, seconds: 60),
                                            .init(kind: .work, meters: 400), .init(kind: .cooldown, seconds: 90)])
        XCTAssertTrue(plan.update(seconds: 60, meters: 100, distanceFresh: true, paused: false))
        XCTAssertTrue(plan.skip(seconds: 80, meters: 150))
        let history = plan.recordedPhases(seconds: 90, meters: 170)
        XCTAssertEqual(history.map(\.seconds), [60, 20, 10])
        XCTAssertEqual(history.map(\.meters), [100, 50, 20])
        XCTAssertEqual(history.map(\.skipped), [false, true, false])
        XCTAssertEqual(history.map(\.inProgress), [false, false, true])
    }

    func testMalformedRestoredTransitionsAreRejected() throws {
        var plan = WorkoutGuidance(phases: [.init(kind: .work, seconds: 60), .init(kind: .recovery, seconds: 60)])
        _ = plan.update(seconds: 60, meters: 100, distanceFresh: true, paused: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        for transitions in [[], [["phaseIndex": 1, "activeSeconds": 60, "recordedMeters": 100, "skipped": false]]] as [[Any]] {
            json["transitions"] = transitions
            let restored = try JSONDecoder().decode(WorkoutGuidance.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(restored.isValid)
        }
    }
}
