import XCTest
@testable import NOOP_Staging

final class HealthKitOriginFilterTests: XCTestCase {
    func testCurrentNoopSourceIsExcluded() {
        XCTAssertTrue(HealthKitBridge.isNoopAuthored(
            currentSource: true, origin: nil, externalUUID: nil))
    }

    func testStableOriginAndLegacyExternalUuidAreExcludedAfterSourceChanges() {
        XCTAssertTrue(HealthKitBridge.isNoopAuthored(
            currentSource: false, origin: "noop", externalUUID: nil))
        XCTAssertTrue(HealthKitBridge.isNoopAuthored(
            currentSource: false, origin: nil, externalUUID: "noop:hr:123"))
    }

    func testGenuineExternalSampleIsAccepted() {
        XCTAssertFalse(HealthKitBridge.isNoopAuthored(
            currentSource: false, origin: "garmin", externalUUID: "external:123"))
    }

    /// A versioned re-save retires the previous revision, which the observer sees as a deletion. Those
    /// must not count as deletions made in Health, or each write-back wakes the next sync.
    func testNoopSyncIdentifiersMarkOwnDeletions() {
        XCTAssertTrue(HealthKitBridge.isNoopSyncIdentifier("HKQuantityTypeIdentifierHeartRate|noop:hr:1759700000"))
        XCTAssertTrue(HealthKitBridge.isNoopSyncIdentifier("HKCategoryTypeIdentifierSleepAnalysis|noop:sleep:1:inBed"))
        XCTAssertTrue(HealthKitBridge.isNoopSyncIdentifier("noop:vital:2026-10-06"))
        XCTAssertFalse(HealthKitBridge.isNoopSyncIdentifier(nil))
        XCTAssertFalse(HealthKitBridge.isNoopSyncIdentifier("com.garmin.sample:noop:1"))
    }
}
