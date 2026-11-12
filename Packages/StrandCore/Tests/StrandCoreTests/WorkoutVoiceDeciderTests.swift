import XCTest
@testable import StrandCore

/// The live workout's voice decisions, shared by iOS and the Android core.
final class WorkoutVoiceDeciderTests: XCTestCase {
    private func settings(voice: Bool = true, hr: Bool = true, motion: Bool = false) -> WorkoutVoiceDecider.Settings {
        .init(voiceEnabled: voice, distanceInterval: 1, timeIntervalSeconds: 600, imperial: false, usesRoute: true,
              heartRateAlert: hr, motionAlert: motion, paceRange: 300...420, speedRangeKmh: nil)
    }

    private func snap(_ t: Int, distance: Double = 0, zone: Int? = nil, speed: Double? = nil) -> WorkoutVoiceDecider.Snapshot {
        .init(now: Double(t), elapsedSeconds: t, distanceMeters: distance, distanceFresh: true, isPaused: false,
              zone: zone, targetZone: 2, speedMps: speed, usesSpeed: false)
    }

    func testAnnouncesEachKilometreOnceAndNotTheBacklog() {
        var d = WorkoutVoiceDecider()
        d.begin(settings: settings(), snapshot: snap(0, distance: 2_500))
        XCTAssertNil(d.tick(settings: settings(), snapshot: snap(1, distance: 2_600)))
        XCTAssertEqual(d.tick(settings: settings(), snapshot: snap(2, distance: 3_000)), .announce(distanceMeters: 3_000))
        XCTAssertNil(d.tick(settings: settings(), snapshot: snap(3, distance: 3_100)))
    }

    func testAZoneWarningNeedsTenSecondsOutsideAndWaitsAMinute() {
        var d = WorkoutVoiceDecider()
        d.begin(settings: settings(), snapshot: snap(0))
        var first: WorkoutVoiceDecider.Decision?
        for t in 1...12 { if let x = d.tick(settings: settings(), snapshot: snap(t, zone: 4)) { first = x; break } }
        XCTAssertEqual(first, .warning(.zoneAbove))
        for t in 13...60 { XCTAssertNil(d.tick(settings: settings(), snapshot: snap(t, zone: 4))) }
    }

    func testWarningsShowEvenWithTheVoiceOffButAnnouncementsDoNot() {
        var d = WorkoutVoiceDecider()
        let off = settings(voice: false, hr: false)
        d.begin(settings: off, snapshot: snap(0))
        XCTAssertNil(d.tick(settings: off, snapshot: snap(1, distance: 1_000)))
    }

    func testAPhaseCueSilencesForEightSeconds() {
        var d = WorkoutVoiceDecider()
        d.begin(settings: settings(), snapshot: snap(0))
        d.phaseCue(at: 1)
        XCTAssertNil(d.tick(settings: settings(), snapshot: snap(2, distance: 1_000)))
    }
}
