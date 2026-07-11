import XCTest
@testable import Strand

/// Pins the Devices card's state-pill priority (#221): "Connected · not paired" must beat "Active · Live"
/// but yield to a reboot's "Reconnecting…". Mirrors the Kotlin `DevicePillStateTest` exactly — a silent
/// reorder on either platform would otherwise only be caught by eyeballing a screenshot.
final class DevicePillStateTests: XCTestCase {

    func testBondRefused_beatsActiveLive_butYieldsToReconnecting() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: true, isLiveConnected: true).label,
            "Connected · not paired")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: true,
                                     bondRefused: true, isLiveConnected: true).label,
            "Reconnecting…")
    }

    func testNormalConnect_isUnaffected() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: true).label,
            "Active · Live")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Active")
    }

    func testNonActiveAndArchived() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: false, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Paired")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: true, isActive: false, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Removed")
    }
}
