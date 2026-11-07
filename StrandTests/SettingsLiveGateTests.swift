import XCTest
import Combine
@testable import Strand

/// A connected strap publishes with every heart rate. The Settings page runs its body again only for what it prints.
@MainActor
final class SettingsLiveGateTests: XCTestCase {
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testTheLiveStreamStaysOutAndAPrintedFactComesThrough() async {
        let live = LiveState()
        let gate = SettingsLiveGate(live: live)
        var published = 0
        let subscription = gate.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        live.heartRate = 72
        live.rr = [812, 830]
        await settle()
        XCTAssertEqual(published, 0)

        live.batteryPct = 64
        await settle()
        XCTAssertEqual(published, 1)

        live.heartRate = 74
        await settle()
        XCTAssertEqual(published, 1)

        live.connected = true
        await settle()
        XCTAssertEqual(published, 2)
    }
}
