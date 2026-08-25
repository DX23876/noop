import XCTest
@testable import WhoopStore

final class EnergyCalibrationModelStoreTests: XCTestCase {
    private func row(enabled: Bool = false) -> EnergyCalibrationModelRow {
        .init(deviceId: "whoop-a", referenceDeviceId: "watch-a", enabled: enabled,
              factor: 1.08, sampleDays: 9, sampleBuckets: 120,
              coefficientOfVariation: 0.07, fittedAt: 1_777_000_000,
              modelVersion: "watch-reference-v1")
    }

    func testFitCanBeSavedPausedEnabledAndResetWithoutLosingDeviceBinding() async throws {
        let store = try await WhoopStore.inMemory()
        let saved = try await store.saveEnergyCalibrationModel(row())
        let initial = try await store.energyCalibrationModel(deviceId: "whoop-a")
        XCTAssertTrue(saved)
        XCTAssertEqual(initial, row())
        XCTAssertFalse(initial?.enabled ?? true)

        let enabled = try await store.setEnergyCalibrationEnabled(deviceId: "whoop-a", enabled: true)
        let active = try await store.energyCalibrationModel(deviceId: "whoop-a")
        XCTAssertTrue(enabled)
        XCTAssertTrue(active?.enabled ?? false)
        XCTAssertEqual(active?.referenceDeviceId, "watch-a")

        let reset = try await store.resetEnergyCalibration(deviceId: "whoop-a")
        let missing = try await store.energyCalibrationModel(deviceId: "whoop-a")
        XCTAssertTrue(reset)
        XCTAssertNil(missing)
    }

    func testInvalidOrMissingFitCannotBeEnabled() async throws {
        let store = try await WhoopStore.inMemory()
        let invalid = EnergyCalibrationModelRow(
            deviceId: "whoop-a", referenceDeviceId: "watch-a", enabled: true,
            factor: 1.5, sampleDays: 1, sampleBuckets: 2,
            coefficientOfVariation: 0.9, fittedAt: 0, modelVersion: "watch-reference-v1")
        let saved = try await store.saveEnergyCalibrationModel(invalid)
        let enabled = try await store.setEnergyCalibrationEnabled(deviceId: "missing", enabled: true)
        let missing = try await store.energyCalibrationModel(deviceId: "whoop-a")
        XCTAssertFalse(saved)
        XCTAssertFalse(enabled)
        XCTAssertNil(missing)
    }
}
