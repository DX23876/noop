import XCTest
@testable import StrandAnalytics

final class HRZoneTrainingEngineTests: XCTestCase {

    private let zones = HRZones.zones(config: HRZoneConfig(mode: .bpm,
                                                           bpmLowerBounds: [100, 120, 140, 160, 180]),
                                      maxHR: 200,
                                      autoSource: "manual")

    func test_all_three_states_are_announced_after_eight_stable_seconds() {
        XCTAssertEqual(cue(afterHolding: 110, targetZone: 2), .increase)
        XCTAssertEqual(cue(afterHolding: 120, targetZone: 2), .target)
        XCTAssertEqual(cue(afterHolding: 140, targetZone: 2), .easeOff)
    }

    func test_profile_zone_boundary_is_inclusive() {
        XCTAssertEqual(HRZoneTrainingEngine.state(forBPM: 119, zoneSet: zones, targetZone: 2), .belowTarget)
        XCTAssertEqual(HRZoneTrainingEngine.state(forBPM: 120, zoneSet: zones, targetZone: 2), .inTarget)
        XCTAssertEqual(HRZoneTrainingEngine.state(forBPM: 140, zoneSet: zones, targetZone: 2), .aboveTarget)
    }

    func test_outside_state_repeats_every_thirty_seconds_but_target_does_not() {
        var outside = HRZoneTrainingEngine()
        for second in 0...8 { _ = outside.update(now: second, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true) }
        for second in 9...37 {
            XCTAssertNil(outside.update(now: second, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true))
        }
        XCTAssertEqual(outside.update(now: 38, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true), .increase)

        var target = HRZoneTrainingEngine()
        for second in 0...8 { _ = target.update(now: second, bpm: 125, zoneSet: zones, targetZone: 2, enabled: true) }
        XCTAssertNil(target.update(now: 100, bpm: 125, zoneSet: zones, targetZone: 2, enabled: true))
    }

    func test_boundary_flapping_never_matures_a_transition() {
        var engine = HRZoneTrainingEngine()
        for second in 0...8 { _ = engine.update(now: second, bpm: 125, zoneSet: zones, targetZone: 2, enabled: true) }
        for second in 9...40 {
            let bpm = second.isMultiple(of: 2) ? 139 : 140
            XCTAssertNil(engine.update(now: second, bpm: bpm, zoneSet: zones, targetZone: 2, enabled: true))
        }
        XCTAssertEqual(engine.stableState, .inTarget)
    }

    func test_missing_reading_and_long_gap_do_not_mature_state_or_reminder() {
        var engine = HRZoneTrainingEngine()
        for second in 0...4 {
            XCTAssertNil(engine.update(now: second, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true))
        }
        XCTAssertNil(engine.update(now: 5, bpm: nil, zoneSet: zones, targetZone: 2, enabled: true))
        for second in 6..<14 {
            XCTAssertNil(engine.update(now: second, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true))
        }
        XCTAssertEqual(engine.update(now: 14, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true), .increase)

        XCTAssertNil(engine.update(now: 100, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true))
        for second in 101...129 {
            XCTAssertNil(engine.update(now: second, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true))
        }
        XCTAssertEqual(engine.update(now: 130, bpm: 110, zoneSet: zones, targetZone: 2, enabled: true), .increase)
    }

    func test_profile_zone_change_restarts_stability_timer() {
        var engine = HRZoneTrainingEngine()
        for second in 0...7 {
            XCTAssertNil(engine.update(now: second, bpm: 125, zoneSet: zones, targetZone: 2, enabled: true))
        }
        let changed = HRZones.zones(config: HRZoneConfig(mode: .bpm,
                                                         bpmLowerBounds: [105, 125, 145, 165, 185]),
                                    maxHR: 205,
                                    autoSource: "manual")
        XCTAssertNil(engine.update(now: 8, bpm: 125, zoneSet: changed, targetZone: 2, enabled: true))
        for second in 9..<16 {
            XCTAssertNil(engine.update(now: second, bpm: 125, zoneSet: changed, targetZone: 2, enabled: true))
        }
        XCTAssertEqual(engine.update(now: 16, bpm: 125, zoneSet: changed, targetZone: 2, enabled: true), .target)
    }

    func test_invalid_or_disabled_target_resets_engine() {
        var engine = HRZoneTrainingEngine()
        for second in 0...8 { _ = engine.update(now: second, bpm: 125, zoneSet: zones, targetZone: 2, enabled: true) }
        XCTAssertNil(engine.update(now: 9, bpm: 125, zoneSet: zones, targetZone: 9, enabled: true))
        XCTAssertNil(engine.stableState)
        XCTAssertNil(engine.update(now: 10, bpm: 125, zoneSet: zones, targetZone: 2, enabled: false))
    }

    private func cue(afterHolding bpm: Int, targetZone: Int) -> HRZoneTrainingEngine.Cue? {
        var engine = HRZoneTrainingEngine()
        for second in 0..<8 {
            XCTAssertNil(engine.update(now: second, bpm: bpm, zoneSet: zones,
                                       targetZone: targetZone, enabled: true))
        }
        return engine.update(now: 8, bpm: bpm, zoneSet: zones,
                             targetZone: targetZone, enabled: true)
    }
}
