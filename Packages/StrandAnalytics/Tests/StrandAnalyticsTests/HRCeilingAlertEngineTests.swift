import XCTest
@testable import StrandAnalytics

final class HRCeilingAlertEngineTests: XCTestCase {

    func test_crossing_warns_immediately() {
        var engine = HRCeilingAlertEngine()
        XCTAssertNil(engine.update(now: 0, bpm: 149, ceilingBPM: 150, enabled: true))
        XCTAssertEqual(engine.update(now: 1, bpm: 151, ceilingBPM: 150, enabled: true), .warning)
        XCTAssertTrue(engine.episodeActive)
    }

    func test_ceiling_boundary_is_inclusive() {
        var engine = HRCeilingAlertEngine()
        XCTAssertEqual(engine.update(now: 0, bpm: 150, ceilingBPM: 150, enabled: true), .warning)
        XCTAssertTrue(engine.episodeActive)
    }

    func test_episode_is_limited_to_three_warnings() {
        var engine = HRCeilingAlertEngine()
        for second in 0...10 { _ = engine.update(now: second, bpm: 155, ceilingBPM: 150, enabled: true) }
        XCTAssertEqual(engine.warningCount, 1)
        var cues: [HRCeilingAlertEngine.Cue] = []
        for second in 11...190 {
            if let cue = engine.update(now: second, bpm: 155, ceilingBPM: 150, enabled: true) {
                cues.append(cue)
            }
        }
        XCTAssertEqual(cues, [.warning, .warning])
        XCTAssertEqual(engine.warningCount, 3)
    }

    func test_every_two_seconds_mode_repeats_single_cues_while_above_ceiling() {
        var engine = HRCeilingAlertEngine()
        var warningTimes: [Int] = []
        for second in 0...20 {
            if engine.update(now: second, bpm: 155, ceilingBPM: 150, enabled: true,
                             reminderMode: .everyTwoSeconds) == .warning {
                warningTimes.append(second)
            }
        }
        XCTAssertEqual(warningTimes, [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20])

        // Buzzing pauses as soon as the current value is below the configured ceiling.
        XCTAssertNil(engine.update(now: 22, bpm: 149, ceilingBPM: 150, enabled: true,
                                   reminderMode: .everyTwoSeconds))
    }

    func test_recovery_requires_hysteresis_and_sustained_dwell_then_rearms() {
        var engine = HRCeilingAlertEngine()
        for second in 0...10 { _ = engine.update(now: second, bpm: 155, ceilingBPM: 150, enabled: true) }

        // Two bpm below is still inside hysteresis and must not recover.
        for second in 11...30 { XCTAssertNil(engine.update(now: second, bpm: 148, ceilingBPM: 150, enabled: true)) }
        for second in 31..<46 { XCTAssertNil(engine.update(now: second, bpm: 147, ceilingBPM: 150, enabled: true)) }
        XCTAssertEqual(engine.update(now: 46, bpm: 147, ceilingBPM: 150, enabled: true), .recovered)
        XCTAssertFalse(engine.episodeActive)

        for second in 47...57 { _ = engine.update(now: second, bpm: 155, ceilingBPM: 150, enabled: true) }
        XCTAssertTrue(engine.episodeActive)
    }

    func test_gap_does_not_mature_a_repeat() {
        var engine = HRCeilingAlertEngine()
        XCTAssertEqual(engine.update(now: 0, bpm: 155, ceilingBPM: 150, enabled: true,
                                     reminderMode: .everyTwoSeconds), .warning)
        XCTAssertNil(engine.update(now: 30, bpm: 155, ceilingBPM: 150, enabled: true,
                                   reminderMode: .everyTwoSeconds))
        XCTAssertNil(engine.update(now: 31, bpm: 155, ceilingBPM: 150, enabled: true,
                                   reminderMode: .everyTwoSeconds))
        XCTAssertEqual(engine.update(now: 32, bpm: 155, ceilingBPM: 150, enabled: true,
                                     reminderMode: .everyTwoSeconds), .warning)
    }

    func test_missing_reading_does_not_mature_a_repeat() {
        var engine = HRCeilingAlertEngine()
        for second in 0...10 { _ = engine.update(now: second, bpm: 155, ceilingBPM: 150, enabled: true) }

        XCTAssertNil(engine.update(now: 70, bpm: nil, ceilingBPM: 150, enabled: true))
        for second in 71..<130 {
            XCTAssertNil(engine.update(now: second, bpm: 155, ceilingBPM: 150, enabled: true))
        }
        XCTAssertEqual(engine.update(now: 130, bpm: 155, ceilingBPM: 150, enabled: true), .warning)
    }

    func test_profile_zone_ceiling_uses_next_profile_band_lower_edge() {
        let zones = HRZones.zones(config: HRZoneConfig(mode: .bpm,
                                                       bpmLowerBounds: [95, 118, 142, 168, 184]),
                                  maxHR: 200,
                                  autoSource: "manual")
        XCTAssertEqual(HRCeilingAlertEngine.profileZoneCeiling(zoneSet: zones, allowedZone: 2), 142)
        XCTAssertEqual(HRCeilingAlertEngine.profileZoneCeiling(zoneSet: zones, allowedZone: 4), 184)
        XCTAssertNil(HRCeilingAlertEngine.profileZoneCeiling(zoneSet: zones, allowedZone: 5))
    }
}
