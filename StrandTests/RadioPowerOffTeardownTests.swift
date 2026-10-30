import XCTest
import CoreBluetooth
@testable import Strand

/// CoreBluetooth on iOS sends no `didDisconnectPeripheral` when Bluetooth powers off, so the radio state change is
/// where the link ends. These pin that a power-off or a reset ends a held link as a disconnect does, that the next
/// link runs the 5/MG handshake again, and that a state change with no link held, or a second one for the same link,
/// changes nothing. Adapted from ayiskakov/noop (W06-083, W06-147, W06-148).
@MainActor
final class RadioPowerOffTeardownTests: XCTestCase {
    private var live: LiveState!
    private var manager: BLEManager!

    override func setUp() async throws {
        live = LiveState()
        manager = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
    }

    override func tearDown() async throws {
        manager = nil
        live = nil
    }

    private func lines(containing needle: String) -> [String] { live.log.filter { $0.contains(needle) } }

    /// What a 5/MG link past its handshake leaves set, as far as a test can set it without a strap.
    private func holdALinkPastTheHandshake() {
        live.connected = true
        live.historyReady = true
        live.charging = true
        manager.whoop5SessionStarted = true
    }

    func testAPowerOffEndsAHeldLinkSoTheNextOneRunsTheHandshake() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertFalse(live.connected, live.log.joined(separator: "\n"))
        XCTAssertFalse(live.historyReady)
        XCTAssertNil(live.charging)
        XCTAssertFalse(manager.whoop5SessionStarted)
        XCTAssertEqual(lines(containing: "Link ended: Bluetooth off").count, 1)
    }

    func testABluetoothResetEndsAHeldLinkToo() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.resetting, peripheralUUID: "strap-1")
        XCTAssertFalse(live.connected)
        XCTAssertFalse(manager.whoop5SessionStarted)
        XCTAssertEqual(lines(containing: "Link ended: Bluetooth resetting").count, 1)
    }

    /// A launch reports `.unknown` and, on macOS, can report a transient `.unauthorized` (#391) while a restored link
    /// is being re-discovered; neither ends it.
    func testAStateThatDoesNotDropLinksLeavesTheLinkAlone() {
        for radio in [CBManagerState.unknown, .unauthorized, .unsupported] {
            holdALinkPastTheHandshake()
            manager.endLinkForRadioState(radio, peripheralUUID: "strap-1")
            XCTAssertTrue(live.connected, "\(radio.rawValue)")
            XCTAssertTrue(manager.whoop5SessionStarted, "\(radio.rawValue)")
        }
        XCTAssertEqual(lines(containing: "Link ended").count, 0)
    }

    func testAPowerOffWithNoLinkHeldSaysNothing() {
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertEqual(lines(containing: "Link ended").count, 0)
    }

    func testASecondPowerOffForTheSameLinkSaysNothing() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        XCTAssertEqual(lines(containing: "Link ended").count, 1)
    }

    // MARK: - A disconnect after the power-off

    private var alreadyEndedLines: Int { lines(containing: "that link already ended at the radio state change").count }
    private var fullDisconnectLines: Int {
        live.log.filter { $0.contains("Disconnected") }.count - alreadyEndedLines
    }

    /// A late disconnect for the link the power-off ended is not torn down again: one line says so.
    func testALateDisconnectForTheSameLinkIsNotTornDownTwice() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.linkDropped(peripheralUUID: "strap-1", error: nil)
        XCTAssertEqual(alreadyEndedLines, 1, live.log.joined(separator: "\n"))
        XCTAssertEqual(fullDisconnectLines, 0)
    }

    /// A disconnect for another peripheral is its own, and runs the handler.
    func testADisconnectForAnotherPeripheralRunsTheHandler() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.linkDropped(peripheralUUID: "strap-2", error: nil)
        XCTAssertEqual(alreadyEndedLines, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(fullDisconnectLines, 1)
    }

    /// The user's own Disconnect after a power-off runs its intentional branch.
    func testTheUsersDisconnectAfterAPowerOffRunsItsOwnBranch() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: "strap-1")
        manager.disconnect()
        manager.linkDropped(peripheralUUID: "strap-1", error: nil)
        XCTAssertEqual(alreadyEndedLines, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "Disconnected (intentional)").count, 1)
    }

    /// A power-off that held no peripheral swallows nothing.
    func testAPowerOffWithNoPeripheralSwallowsNoDisconnect() {
        holdALinkPastTheHandshake()
        manager.endLinkForRadioState(.poweredOff, peripheralUUID: nil)
        manager.linkDropped(peripheralUUID: "strap-1", error: nil)
        XCTAssertEqual(alreadyEndedLines, 0)
    }
}
