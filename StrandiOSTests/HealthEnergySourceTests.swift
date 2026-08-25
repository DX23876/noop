#if os(iOS)
import XCTest
@testable import StrandiOS

final class HealthEnergySourceTests: XCTestCase {
    func testAppleWatchClassificationUsesProductOrSourceName() {
        XCTAssertEqual(HealthKitBridge.energySourceKind(
            sourceName: "Jane’s Apple Watch", bundleIdentifier: "com.apple.health",
            productType: nil, isCurrentApp: false), .appleWatch)
        XCTAssertEqual(HealthKitBridge.energySourceKind(
            sourceName: "Health", bundleIdentifier: "com.apple.health",
            productType: "Watch6,2", isCurrentApp: false), .appleWatch)
    }

    func testCurrentAppAndPhoneAreNeverCalibrationEligible() {
        XCTAssertEqual(HealthKitBridge.energySourceKind(
            sourceName: "NOOP", bundleIdentifier: "com.noop", productType: nil,
            isCurrentApp: true), .noop)
        XCTAssertEqual(HealthKitBridge.energySourceKind(
            sourceName: "Jane’s iPhone", bundleIdentifier: "com.apple.health",
            productType: "iPhone18,1", isCurrentApp: false), .iPhone)
    }
}
#endif
