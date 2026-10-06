import XCTest
@testable import Strand

final class WorkoutFeedbackPreferencesTests: XCTestCase {
    func testDeferredCadenceWarningsIgnoreAnEarlierOptIn() throws {
        let suite = "WorkoutFeedbackPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: WorkoutFeedbackPreferences.cadenceAlertKey)
        defaults.set(80.0, forKey: WorkoutFeedbackPreferences.lowCadenceKey)
        defaults.set(180.0, forKey: WorkoutFeedbackPreferences.highCadenceKey)

        XCTAssertNil(WorkoutFeedbackPreferences.cadenceWarningRange(defaults))
        XCTAssertTrue(defaults.bool(forKey: WorkoutFeedbackPreferences.cadenceAlertKey))
        XCTAssertEqual(defaults.double(forKey: WorkoutFeedbackPreferences.lowCadenceKey), 80)
        XCTAssertEqual(defaults.double(forKey: WorkoutFeedbackPreferences.highCadenceKey), 180)
    }

    func testDeferredCadenceWarningsAreOffWithoutSavedSettings() throws {
        let suite = "WorkoutFeedbackPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(WorkoutFeedbackPreferences.cadenceWarningRange(defaults))
    }

    func testOtherFeedbackIntervalsAreUnaffected() throws {
        let suite = "WorkoutFeedbackPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.5, forKey: WorkoutFeedbackPreferences.distanceIntervalKey)
        defaults.set(300.0, forKey: WorkoutFeedbackPreferences.timeIntervalKey)
        XCTAssertEqual(WorkoutFeedbackPreferences.distanceInterval(defaults), 0.5)
        XCTAssertEqual(WorkoutFeedbackPreferences.timeInterval(defaults), 300)
        XCTAssertTrue(WorkoutFeedbackPreferences.supportsAutoPause(sport: "Running", gps: true))
    }
}
