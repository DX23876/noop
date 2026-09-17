import XCTest
@testable import Strand

/// The iOS "Sync Strap" shortcut can arrive while NOOP is still launching and reconnecting in the background,
/// before any link can serve. The request is parked and the connect handshake's on-connect kick consumes it:
/// a fresh request upgrades that kick to the un-floored `.manual` tier; a stale or absent one leaves the
/// ordinary `.connect` kick alone. Pure value logic, no CoreBluetooth seam.
final class PendingManualSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoPendingRequestIsAnOrdinaryConnectKick() {
        XCTAssertEqual(BLEManager.connectSyncTrigger(pendingManualRequestedAt: nil, now: now), .connect)
    }

    func testFreshRequestUpgradesToManual() {
        let at = now.addingTimeInterval(-30)
        XCTAssertEqual(BLEManager.connectSyncTrigger(pendingManualRequestedAt: at, now: now), .manual)
    }

    func testRequestOlderThanTTLIsIgnored() {
        let at = now.addingTimeInterval(-(BLEManager.pendingManualSyncTTL + 1))
        XCTAssertEqual(BLEManager.connectSyncTrigger(pendingManualRequestedAt: at, now: now), .connect)
    }

    func testRequestExactlyAtTTLIsIgnored() {
        let at = now.addingTimeInterval(-BLEManager.pendingManualSyncTTL)
        XCTAssertEqual(BLEManager.connectSyncTrigger(pendingManualRequestedAt: at, now: now), .connect)
    }

    func testFutureDatedRequestIsIgnored() {
        // A clock that jumped backwards must not turn a request into an indefinitely fresh one.
        let at = now.addingTimeInterval(60)
        XCTAssertEqual(BLEManager.connectSyncTrigger(pendingManualRequestedAt: at, now: now), .connect)
    }

    /// The request must outlive the process: iOS can end the background-launched app and relaunch it through
    /// state restoration when the strap reconnects, and that relaunch is where the connect completes.
    func testRequestIsPersistedUnderAStableKey() {
        XCTAssertEqual(BLEManager.pendingManualSyncKey, "sync.pendingManualRequestedAt")
    }
}
