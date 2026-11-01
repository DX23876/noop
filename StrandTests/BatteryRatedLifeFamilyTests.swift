import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The strap-battery "days left" fallback must follow the strap family on every path that picks it, not
/// only on the Connect path. A WHOOP 5.0 that iOS relaunched into the background (`willRestoreState`)
/// kept the WHOOP 4.0 default of 108 h, so 91 % read as "About 4 days" instead of about 11. And a
/// reconnect inside one session cleared the SoC history without reading it back, so the estimate fell
/// back to that rated figure even with days of discharge already on disk.
@MainActor
final class BatteryRatedLifeFamilyTests: XCTestCase {
    private let modelKey = "selectedWhoopModel"
    private var savedModel: String?

    override func setUp() async throws {
        savedModel = UserDefaults.standard.string(forKey: modelKey)
    }

    override func tearDown() async throws {
        if let savedModel {
            UserDefaults.standard.set(savedModel, forKey: modelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: modelKey)
        }
    }

    /// A relaunched process hydrates the persisted 5/MG pick before any Connect runs; the rated life has
    /// to match it from the start, since the restore path never reaches `connectCore`.
    func testAPersistedFiveModelGetsTheFiveRatedLifeAtLaunch() {
        UserDefaults.standard.set(WhoopModel.whoop5mg.rawValue, forKey: modelKey)
        let live = LiveState()
        _ = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
        XCTAssertEqual(live.batteryRatedHours, BatteryEstimator.ratedLifeHoursWhoop5)
    }

    func testAPersistedFourModelKeepsTheFourRatedLife() {
        UserDefaults.standard.set(WhoopModel.whoop4.rawValue, forKey: modelKey)
        let live = LiveState()
        _ = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
        XCTAssertEqual(live.batteryRatedHours, BatteryEstimator.ratedLifeHoursWhoop4)
    }

    /// The SoC buffer is emptied on every disconnect; reading the persisted series back must restore it,
    /// so the next link fits the measured discharge instead of the rated fallback.
    func testTheSeedRestoresTheDischargeHistoryAfterADisconnectCleared() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("battery-seed-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try await WhoopStore(path: path)
        let deviceId = "rig-\(UUID().uuidString)"
        let now = 1_800_000_000
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.insert(Streams(battery: [
            BatterySample(ts: now - 24 * 3600, soc: 100, mv: nil),
            BatterySample(ts: now - 3600, soc: 91, mv: nil),
        ]), deviceId: deviceId)
        let live = LiveState()
        let manager = BLEManager(state: live, deviceId: deviceId, collector: nil)

        live.clearBiometrics()
        XCTAssertTrue(live.batterySamples.isEmpty)
        await manager.seedBatteryHistory(from: store, now: now)

        XCTAssertEqual(live.batterySamples.map(\.soc), [100, 91])
        XCTAssertEqual(live.batteryEstimate?.source, .measured)
    }
}
