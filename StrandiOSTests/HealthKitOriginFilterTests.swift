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
}
