import XCTest
@testable import StrandDesign

/// Pins the day-cycle scene mapping: every hour resolves to one of ten slots, and each motif turns a slot
/// into its own asset name, so adding a motif can never shift which hour shows which light.
final class SceneMotifTests: XCTestCase {

    func testMeadowNamesAreTheHistoricalOnes() {
        let expected = [1, 1, 1, 1, 1, 2, 3, 6, 7, 7, 8, 8, 10, 10, 10, 10, 10, 9, 9, 5, 5, 4, 4, 4]
        XCTAssertEqual((0..<24).map { DayCycleScene.assetName(hour: $0) }, expected.map { "scene\($0)" })
    }

    func testEveryMotifFollowsTheSameSlots() {
        let prefixes: [SceneMotif: String] = [.alps: "alps", .coast: "coast", .meadow: "scene"]
        XCTAssertEqual(Set(prefixes.keys), Set(SceneMotif.allCases), "a new motif needs a prefix here")
        for motif in SceneMotif.allCases {
            for hour in 0..<24 {
                let slot = DayCycleScene.slot(hour: hour)
                XCTAssertEqual(DayCycleScene.assetName(hour: hour, motif: motif), "\(prefixes[motif]!)\(slot)")
            }
        }
    }

    func testEveryHourMapsIntoTenSlotsAndEverySlotIsUsed() {
        let slots = Set((0..<24).map { DayCycleScene.slot(hour: $0) })
        XCTAssertEqual(slots, Set(1...10))
    }

    func testOutOfRangeHoursWrap() {
        XCTAssertEqual(DayCycleScene.slot(hour: 24), DayCycleScene.slot(hour: 0))
        XCTAssertEqual(DayCycleScene.slot(hour: -1), DayCycleScene.slot(hour: 23))
        XCTAssertEqual(DayCycleScene.slot(hour: 49), DayCycleScene.slot(hour: 1))
    }

    func testResolveIsTolerantAndDefaultsToAlps() {
        XCTAssertEqual(SceneMotif.storageKey, "noop.sceneMotif")
        XCTAssertEqual(SceneMotif.resolve("meadow"), .meadow)
        XCTAssertEqual(SceneMotif.resolve("alps"), .alps)
        XCTAssertEqual(SceneMotif.resolve("coast"), .coast)
        XCTAssertEqual(SceneMotif.resolve("nonsense"), .alps)
        XCTAssertEqual(SceneMotif.resolve(""), .alps)
    }
}
