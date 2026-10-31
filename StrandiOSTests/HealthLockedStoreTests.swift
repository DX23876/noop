import XCTest
import HealthKit
@testable import NOOP_Staging

/// A background pass that meets the locked Health store is owed, not failed, so it must never reach
/// the Apple Health screen as "Protected health data is inaccessible".
final class HealthLockedStoreTests: XCTestCase {
    private let lockedStore = NSError(domain: HKErrorDomain,
                                      code: HKError.Code.errorDatabaseInaccessible.rawValue)

    func testLockedStoreErrorIsDeferredEvenIfUnlockedSinceItWasThrown() {
        XCTAssertTrue(HealthKitBridge.isLockedStoreFailure(lockedStore, protectedDataAvailable: true))
    }

    func testAnyFailureWhileLockedIsDeferred() {
        // A read that failed without an error (the sync's per-read ledger) or with another error while
        // the device is locked is retried after the unlock instead of being shown.
        XCTAssertTrue(HealthKitBridge.isLockedStoreFailure(nil, protectedDataAvailable: false))
        let other = NSError(domain: HKErrorDomain, code: HKError.Code.errorInvalidArgument.rawValue)
        XCTAssertTrue(HealthKitBridge.isLockedStoreFailure(other, protectedDataAvailable: false))
    }

    func testGenuineFailureWhileUnlockedIsSurfaced() {
        let denied = NSError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue)
        XCTAssertFalse(HealthKitBridge.isLockedStoreFailure(denied, protectedDataAvailable: true))
        XCTAssertFalse(HealthKitBridge.isLockedStoreFailure(nil, protectedDataAvailable: true))
        let sameCodeOtherDomain = NSError(domain: NSCocoaErrorDomain,
                                          code: HKError.Code.errorDatabaseInaccessible.rawValue)
        XCTAssertFalse(HealthKitBridge.isLockedStoreFailure(sameCodeOtherDomain, protectedDataAvailable: true))
    }
}
