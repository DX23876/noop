import XCTest
import Combine
import WhoopStore
@testable import Strand

/// 2026-10-02 field case: an old 5.0 the phone still held connected at launch, the coordinator was wired
/// after the link was up, and the replayed uuid with the bond already encrypted was read as the #52
/// stale-pin handoff, so the paired MG's row was re-pointed onto the 5.0. A connect alone must never
/// re-point a row; only BLEManager's explicit confirmation may.
@MainActor
final class WhoopReadoptionTests: XCTestCase {
    private let mg = "00000000-0000-4000-8000-0000000000A2"
    private let oldStrap = "00000000-0000-4000-8000-000000000501"

    private func makeCoordinator(connected: AnyPublisher<String?, Never>,
                                 readoption: AnyPublisher<String, Never>,
                                 live: LiveState,
                                 pins: @escaping (String?) -> Void = { _ in },
                                 ids: @escaping (String) -> Void = { _ in }) async throws -> (SourceCoordinator, DeviceRegistry) {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        registry.setPeripheralId("my-whoop", peripheralId: mg)
        let coordinator = SourceCoordinator(
            registry: registry, live: live, storeHandle: { nil },
            startWhoop: {}, stopWhoop: {},
            setWhoopPreferredPeripheral: pins, setWhoopActiveDeviceId: ids,
            connectedPeripheralUUID: connected, readoptionConfirmed: readoption)
        return (coordinator, registry)
    }

    func testAConnectToAnotherStrapNeverRepointsTheRowEvenWithTheBondUp() async throws {
        let live = LiveState()
        live.encryptedBond = true   // what a late-wired coordinator observed at launch
        let connected = CurrentValueSubject<String?, Never>(oldStrap)
        let (coordinator, registry) = try await makeCoordinator(
            connected: connected.eraseToAnyPublisher(),
            readoption: Empty().eraseToAnyPublisher(), live: live)
        coordinator.start()
        XCTAssertEqual(registry.devices.first { $0.id == "my-whoop" }?.peripheralId, mg)
    }

    func testOnlyAConfirmedHandoffRepointsTheRow() async throws {
        let readoption = PassthroughSubject<String, Never>()
        let (coordinator, registry) = try await makeCoordinator(
            connected: Empty().eraseToAnyPublisher(),
            readoption: readoption.eraseToAnyPublisher(), live: LiveState())
        coordinator.start()
        readoption.send(oldStrap)
        XCTAssertEqual(registry.devices.first { $0.id == "my-whoop" }?.peripheralId, oldStrap)
    }

    /// Re-targeting the active WHOOP after a pairing re-pins the strap and re-states the sample id.
    func testRetargetPinsTheNewStrapAndTheWhoopId() async throws {
        var pins: [String?] = []
        var ids: [String] = []
        let (coordinator, registry) = try await makeCoordinator(
            connected: Empty().eraseToAnyPublisher(), readoption: Empty().eraseToAnyPublisher(),
            live: LiveState(), pins: { pins.append($0) }, ids: { ids.append($0) })
        coordinator.activeDeviceChanged(to: "my-whoop")
        registry.setPeripheralId("my-whoop", peripheralId: oldStrap)
        coordinator.retargetActiveWhoop()
        XCTAssertEqual(pins.last ?? nil, oldStrap)
        XCTAssertEqual(ids, ["my-whoop", "my-whoop"])
    }
}
