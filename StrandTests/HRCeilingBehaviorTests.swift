import XCTest
@testable import Strand

@MainActor
final class HRCeilingBehaviorTests: XCTestCase {

    func test_hr_coaching_haptic_priority_is_ceiling_then_zone_then_live_session() {
        XCTAssertEqual(HRCoachingHapticOwner.resolve(ceilingActive: true,
                                                     zoneTrainingActive: true,
                                                     liveSessionActive: true), .ceiling)
        XCTAssertEqual(HRCoachingHapticOwner.resolve(ceilingActive: false,
                                                     zoneTrainingActive: true,
                                                     liveSessionActive: true), .zoneTraining)
        XCTAssertEqual(HRCoachingHapticOwner.resolve(ceilingActive: false,
                                                     zoneTrainingActive: false,
                                                     liveSessionActive: true), .liveSession)
        XCTAssertEqual(HRCoachingHapticOwner.resolve(ceilingActive: false,
                                                     zoneTrainingActive: false,
                                                     liveSessionActive: false), .none)
    }
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "hr-ceiling-behavior-\(UUID().uuidString)")!
    }

    func test_defaults_preserve_legacy_top_zone_behavior() {
        let store = BehaviorStore(defaults: defaults())
        XCTAssertFalse(store.zoneCoaching)
        XCTAssertEqual(store.hrCeilingThresholdMode, .zone)
        XCTAssertEqual(store.hrCeilingAllowedZone, 4)
        XCTAssertEqual(store.hrCeilingBPM, 150)
        XCTAssertEqual(store.hrCeilingScope, .always)
        XCTAssertEqual(store.hrCeilingReminderMode, .standard)
    }

    func test_configuration_roundTrips() {
        let d = defaults()
        var store: BehaviorStore? = BehaviorStore(defaults: d)
        store?.zoneCoaching = true
        store?.hrCeilingThresholdMode = .bpm
        store?.hrCeilingAllowedZone = 2
        store?.hrCeilingBPM = 135
        store?.hrCeilingScope = .workout
        store?.hrCeilingReminderMode = .everyTwoSeconds
        store = nil

        let restored = BehaviorStore(defaults: d)
        XCTAssertTrue(restored.zoneCoaching)
        XCTAssertEqual(restored.hrCeilingThresholdMode, .bpm)
        XCTAssertEqual(restored.hrCeilingAllowedZone, 2)
        XCTAssertEqual(restored.hrCeilingBPM, 135)
        XCTAssertEqual(restored.hrCeilingScope, .workout)
        XCTAssertEqual(restored.hrCeilingReminderMode, .everyTwoSeconds)
    }

    func test_invalid_persisted_values_are_clamped_or_defaulted() {
        let d = defaults()
        d.set("unknown", forKey: "behavior.hrCeilingThresholdMode")
        d.set(9, forKey: "behavior.hrCeilingAllowedZone")
        d.set(999, forKey: "behavior.hrCeilingBPM")
        d.set("unknown", forKey: "behavior.hrCeilingScope")
        d.set("unknown", forKey: "behavior.hrCeilingReminderMode")

        let store = BehaviorStore(defaults: d)
        XCTAssertEqual(store.hrCeilingThresholdMode, .zone)
        XCTAssertEqual(store.hrCeilingAllowedZone, 4)
        XCTAssertEqual(store.hrCeilingBPM, 220)
        XCTAssertEqual(store.hrCeilingScope, .always)
        XCTAssertEqual(store.hrCeilingReminderMode, .standard)
    }
}
