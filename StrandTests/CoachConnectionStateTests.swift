import XCTest
@testable import Strand

/// Pins the P4 fixes to provider/connection state. Deliberately does NOT touch `AIKeyStore` — it's a
/// real Keychain item under the SAME service/account the live app uses on this machine, so a test that
/// saved/cleared a key there could clobber a developer's actual saved coach key. What's covered instead
/// is the part that's both fully test-safe and the actual bug: that "disconnect" and "the stored key"
/// are now separate pieces of state (`explicitlyDisconnected` vs `AIKeyStore`), never conflated again.
///
/// - 4.2 (disconnect must update state immediately/consistently): `disconnect()`/`reconnect()` toggle
///   `explicitlyDisconnected` directly — no separate flag anywhere to drift out of sync.
/// - 4.3 (disconnect must never delete the key): `disconnect()`/`reconnect()` for a CLOUD provider never
///   touch `customConnected` (proof by construction: touching `AIKeyStore` isn't even reachable from
///   these two methods for a cloud provider — the only Keychain-touching methods are `setKey`/`clearKey`,
///   neither of which `disconnect()` calls).
@MainActor
final class CoachConnectionStateTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-connection-state-\(UUID().uuidString)"))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ai.explicitlyDisconnected")
        super.tearDown()
    }

    func testFreshEngineIsNotExplicitlyDisconnected() {
        // An existing user who already had a key saved before this flag existed must read as still
        // connected — no migration step, just "not disconnected" as the honest default.
        let engine = makeEngine()
        XCTAssertFalse(engine.explicitlyDisconnected)
    }

    func testDisconnectOnACloudProviderSetsExplicitlyDisconnectedAndLeavesCustomConnectedAlone() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.customConnected = true   // must be untouched by a cloud disconnect
        engine.disconnect()
        XCTAssertTrue(engine.explicitlyDisconnected)
        XCTAssertTrue(engine.customConnected, "disconnecting a cloud provider must not touch Custom's state")
    }

    func testDisconnectOnCustomProviderClearsCustomConnectedAndLeavesExplicitlyDisconnectedAlone() {
        let engine = makeEngine()
        engine.provider = .custom
        engine.customConnected = true
        engine.disconnect()
        XCTAssertFalse(engine.customConnected)
        XCTAssertFalse(engine.explicitlyDisconnected, "disconnecting Custom must not touch the cloud flag")
    }

    func testReconnectClearsExplicitlyDisconnected() {
        let engine = makeEngine()
        engine.provider = .openAI
        engine.disconnect()
        XCTAssertTrue(engine.explicitlyDisconnected)
        engine.reconnect()
        XCTAssertFalse(engine.explicitlyDisconnected)
    }

    /// `explicitlyDisconnected` persists across engine instances (a relaunch), the same way
    /// `customConnected`/`provider`/`model` already do — proof it's wired into UserDefaults, not just an
    /// in-memory flag that would silently reset every app launch.
    func testExplicitlyDisconnectedPersistsAcrossEngineInstances() {
        let first = makeEngine()
        first.provider = .anthropic
        first.disconnect()
        XCTAssertTrue(first.explicitlyDisconnected)

        let second = AICoachEngine(repo: Repository(deviceId: "test-connection-state-second-\(UUID().uuidString)"))
        XCTAssertTrue(second.explicitlyDisconnected, "a fresh engine instance must restore the persisted flag")
    }
}
