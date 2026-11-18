import XCTest
import Combine
import WhoopStore
@testable import Strand

/// A strap removed and added again had to wait for an app relaunch before anything connected.
///
/// `BLEManager` published the uuid of the strap it connected to and never took it back, so
/// `SourceCoordinator` held the last-connected uuid for the rest of the session. Making the re-added row
/// active then matched its adopt-in-place branch, which exists for "make active on the strap we are
/// already talking to" (#74): it re-points the targeting and leaves the connection alone. With nothing
/// connected, that means nothing happens at all.
///
/// Two halves, so neither can quietly go back: the engine says when the link ends, and the coordinator
/// reconnects when it hears that.
@MainActor
final class ReleasedStrapReconnectTests: XCTestCase {
    private let strap = "00000000-0000-4000-8000-0000000000A2"

    // MARK: - The engine takes the uuid back

    private func manager(_ live: LiveState) -> BLEManager {
        BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
    }

    func testAnOrdinaryDisconnectTakesTheConnectedUuidBack() {
        let live = LiveState()
        let ble = manager(live)
        ble.noteConnectedPeripheralForTesting(strap)
        XCTAssertEqual(ble.connectedPeripheralUUID, strap)

        live.connected = true
        ble.linkDropped(peripheralUUID: strap, error: nil)
        XCTAssertNil(ble.connectedPeripheralUUID,
                     "the coordinator's disconnect edge never arrives while this holds the old uuid")
    }

    /// CoreBluetooth sends no disconnect for a Bluetooth power-off, so that teardown must publish it too.
    func testBluetoothOffTakesTheConnectedUuidBack() {
        let live = LiveState()
        let ble = manager(live)
        ble.noteConnectedPeripheralForTesting(strap)
        live.connected = true
        ble.endLinkForRadioState(.poweredOff, peripheralUUID: strap)
        XCTAssertNil(ble.connectedPeripheralUUID)
    }

    /// Releasing a strap is the path the report walked, and it does not run through `resetLinkState`.
    /// A release while the radio is off gets no disconnect callback at all, so the clearing cannot be
    /// left to one.
    func testReleasingAStrapTakesTheConnectedUuidBack() {
        let live = LiveState()
        let ble = manager(live)
        ble.noteConnectedPeripheralForTesting(strap)
        ble.forgetDevice(strap)
        XCTAssertNil(ble.connectedPeripheralUUID,
                     "a release is meant to leave nothing of that strap behind (#747/#750, #1635)")
    }

    // MARK: - The coordinator reconnects once it hears it

    private func coordinator(connected: AnyPublisher<String?, Never>,
                             started: @escaping () -> Void) async throws -> (SourceCoordinator, DeviceRegistry) {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        // The row the wearer re-adds: a second WHOOP entry carrying the same physical strap, which is what
        // a re-add out of the removed section produces. The seeded "my-whoop" row stays as the active one,
        // so the first branch ("already streaming this exact WHOOP") cannot swallow the switch.
        let now = Int(Date().timeIntervalSince1970)
        registry.add(PairedDevice(id: "whoop-readded", brand: "WHOOP", model: "WHOOP 4.0",
                                  peripheralId: strap, sourceKind: .liveBLE,
                                  capabilities: [], status: .paired, addedAt: now, lastSeenAt: now))
        let coordinator = SourceCoordinator(
            registry: registry, live: LiveState(), storeHandle: { nil },
            startWhoop: started, stopWhoop: {},
            setWhoopPreferredPeripheral: { _ in }, setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: connected, readoptionConfirmed: Empty().eraseToAnyPublisher())
        return (coordinator, registry)
    }

    func testMakingAReleasedStrapsRowActiveReconnectsOnceTheLinkEndWasPublished() async throws {
        var starts = 0
        let connected = CurrentValueSubject<String?, Never>(nil)
        let (coordinator, _) = try await coordinator(connected: connected.eraseToAnyPublisher(),
                                                     started: { starts += 1 })
        coordinator.start()
        coordinator.activeDeviceChanged(to: "my-whoop")
        connected.send(strap)      // the link comes up
        starts = 0                 // only what the re-add does is interesting
        connected.send(nil)        // the release drops it, which is what this fix publishes

        coordinator.activeDeviceChanged(to: "whoop-readded")
        XCTAssertEqual(starts, 1, "the re-added row must reconnect, not adopt a link that is gone")
    }

    /// The counter-case, and the whole reason the publish matters: with the uuid still standing, the same
    /// re-add is read as "we are already on that strap" and nothing reconnects. This is what the field
    /// report described, and it must stay failing-by-construction rather than by a comment.
    func testWithoutThatPublishTheReAddAdoptsALinkThatIsGone() async throws {
        var starts = 0
        let connected = CurrentValueSubject<String?, Never>(nil)
        let (coordinator, _) = try await coordinator(connected: connected.eraseToAnyPublisher(),
                                                     started: { starts += 1 })
        coordinator.start()
        coordinator.activeDeviceChanged(to: "my-whoop")
        connected.send(strap)
        starts = 0

        coordinator.activeDeviceChanged(to: "whoop-readded")
        XCTAssertEqual(starts, 0, "adopt-in-place is right while the link really is up (#74)")
    }
}
