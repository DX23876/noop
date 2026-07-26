import XCTest
@testable import Strand

/// Pins docs/feature-spec.md §4: per-metric visible/sortOrder persisted config, extensible (a new
/// metric id needs no change to the merge/edit logic), plus the global 2-vs-3 `gridDensity` setting.
final class VitalTileConfigTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeEmptySavedYieldsFullRegistryVisibleInOrder() {
        let configs = VitalTileConfigStore.normalize([])
        XCTAssertEqual(configs.map(\.metricId), VitalGridMetric.available)
        XCTAssertTrue(configs.allSatisfy(\.visible))
        XCTAssertEqual(configs.map(\.sortOrder), configs.map(\.sortOrder).sorted())
    }

    func testNormalizePreservesUserCustomization() {
        let saved = [
            VitalTileConfig(metricId: "my-whoop:hrv", visible: false, sortOrder: 5),
            VitalTileConfig(metricId: "my-whoop:rhr", visible: true, sortOrder: 0),
        ]
        let normalized = VitalTileConfigStore.normalize(saved, availableIds: ["my-whoop:hrv", "my-whoop:rhr"])
        let hrv = normalized.first { $0.metricId == "my-whoop:hrv" }
        let rhr = normalized.first { $0.metricId == "my-whoop:rhr" }
        XCTAssertEqual(hrv?.visible, false)
        XCTAssertEqual(hrv?.sortOrder, 5)
        XCTAssertEqual(rhr?.visible, true)
        XCTAssertEqual(rhr?.sortOrder, 0)
    }

    func testNormalizeAppendsNewlyAvailableMetric() {
        // Simulates the registry growing by one id after the user already had a saved layout —
        // extensibility (§4): no other logic needs to change for the new tile to appear.
        let saved = [VitalTileConfig(metricId: "my-whoop:hrv", visible: true, sortOrder: 0)]
        let normalized = VitalTileConfigStore.normalize(saved, availableIds: ["my-whoop:hrv", "my-whoop:new_metric"])
        XCTAssertEqual(normalized.map(\.metricId), ["my-whoop:hrv", "my-whoop:new_metric"])
        let newTile = normalized.first { $0.metricId == "my-whoop:new_metric" }
        XCTAssertEqual(newTile?.visible, true)
        XCTAssertEqual(newTile?.sortOrder, 1)
    }

    func testNormalizeDropsRetiredMetric() {
        let saved = [
            VitalTileConfig(metricId: "my-whoop:hrv", visible: true, sortOrder: 0),
            VitalTileConfig(metricId: "my-whoop:retired", visible: true, sortOrder: 1),
        ]
        let normalized = VitalTileConfigStore.normalize(saved, availableIds: ["my-whoop:hrv"])
        XCTAssertEqual(normalized.map(\.metricId), ["my-whoop:hrv"])
    }

    func testNormalizeSortsBySortOrder() {
        let saved = [
            VitalTileConfig(metricId: "my-whoop:hrv", visible: true, sortOrder: 2),
            VitalTileConfig(metricId: "my-whoop:rhr", visible: true, sortOrder: 0),
        ]
        let normalized = VitalTileConfigStore.normalize(saved, availableIds: ["my-whoop:hrv", "my-whoop:rhr"])
        XCTAssertEqual(normalized.map(\.metricId), ["my-whoop:rhr", "my-whoop:hrv"])
    }

    // MARK: - visibleTiles

    func testVisibleTilesFiltersHiddenAndSorts() {
        let configs = [
            VitalTileConfig(metricId: "a", visible: true, sortOrder: 2),
            VitalTileConfig(metricId: "b", visible: false, sortOrder: 0),
            VitalTileConfig(metricId: "c", visible: true, sortOrder: 1),
        ]
        XCTAssertEqual(VitalTileConfigStore.visibleTiles(configs).map(\.metricId), ["c", "a"])
    }

    // MARK: - density

    func testDensityPassesThroughValidValues() {
        XCTAssertEqual(VitalTileConfigStore.density(2), 2)
        XCTAssertEqual(VitalTileConfigStore.density(3), 3)
    }

    func testDensityClampsInvalidValuesToThree() {
        for raw in [0, 1, 4, -1] {
            XCTAssertEqual(VitalTileConfigStore.density(raw), 3, "raw density \(raw) should clamp to 3")
        }
    }

    // MARK: - persistence round trip

    private func isolatedDefaults() -> UserDefaults {
        let name = "vitaltileconfig.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testStoreRoundTrip() {
        let d = isolatedDefaults()
        let configs = [
            VitalTileConfig(metricId: "my-whoop:hrv", visible: false, sortOrder: 3),
            VitalTileConfig(metricId: "my-whoop:rhr", visible: true, sortOrder: 0),
        ]
        VitalTileConfigStore.save(configs, to: d)
        let loaded = VitalTileConfigStore.load(from: d)
        XCTAssertEqual(loaded, VitalTileConfigStore.normalize(configs))
    }

    func testStoreWithNoSavedValueReturnsFullRegistry() {
        let d = isolatedDefaults()
        XCTAssertEqual(VitalTileConfigStore.load(from: d).map(\.metricId), VitalGridMetric.available)
    }
}
