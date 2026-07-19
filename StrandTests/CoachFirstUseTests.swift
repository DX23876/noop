import XCTest
@testable import Strand

/// Pins the P6 first-use acknowledgement key. The dialog itself is UI, but the KEY that records "already
/// acknowledged" must stay stable: if it silently changed, every existing user would be shown the
/// one-time note again. This is the cheap guard against that drift.
final class CoachFirstUseTests: XCTestCase {

    func testAcknowledgedKeyIsStable() {
        XCTAssertEqual(CoachFirstUse.acknowledgedKey, "coach.firstUseAcknowledged")
    }

    /// The @AppStorage default is "not acknowledged", so a genuinely new user sees the note; the key
    /// must therefore read false when absent from UserDefaults.
    func testDefaultsToNotAcknowledgedWhenUnset() {
        UserDefaults.standard.removeObject(forKey: CoachFirstUse.acknowledgedKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: CoachFirstUse.acknowledgedKey))
    }
}
