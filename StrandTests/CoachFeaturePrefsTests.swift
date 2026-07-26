import XCTest
@testable import Strand

final class CoachFeaturePrefsTests: XCTestCase {
    func testFeatureStartsDisabledUntilExplicitlyEnabled() {
        let suite = "CoachFeaturePrefsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(CoachFeaturePrefs.isEnabled(defaults: defaults))

        defaults.set(true, forKey: CoachFeaturePrefs.enabledKey)
        XCTAssertTrue(CoachFeaturePrefs.isEnabled(defaults: defaults))

        defaults.set(false, forKey: CoachFeaturePrefs.enabledKey)
        XCTAssertFalse(CoachFeaturePrefs.isEnabled(defaults: defaults))
    }
}
