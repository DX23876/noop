import XCTest
import StrandCore
import StrandAnalytics
import WhoopStore
import WhoopProtocol

final class WorkoutPhysiologyTests: XCTestCase {
    func testRecordingDeviceWinsForBothCurveAndConfiguredZones() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 1_793_001_600
        for (id, bpm) in [("active", 190), ("gym", 130), ("my-whoop", 170)] {
            try await store.insert(Streams(hr: (0..<20).map { HRSample(ts: start + $0 * 60, bpm: bpm) }), deviceId: id)
        }
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: ["gym"])
        let buckets = await WorkoutPhysiology.buckets(reader: reader, from: start, to: start + 1_200, source: "native-training:gym")
        XCTAssertFalse(buckets.isEmpty)
        XCTAssertTrue(buckets.allSatisfy { $0.bpm == 130 })
        let zones = HRZones.zones(bpmEdges: [100, 120, 140, 160, 180, 200], maxHR: 200)
        let minutes = await WorkoutPhysiology.zoneMinutes(reader: reader, from: start, to: start + 1_200,
            zoneSet: zones, source: "native-training:gym")
        XCTAssertEqual(minutes, [0, 20, 0, 0, 0], "the active strap's zone-five trace must not leak into the gym strap's session")
        let detected = await WorkoutPhysiology.buckets(reader: reader, from: start, to: start + 1_200, source: "gym-noop")
        XCTAssertEqual(detected, buckets)
    }

    func testUnknownOrReversedWindowsRemainUnmeasured() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])
        let zones = HRZones.zones(maxHR: 190)
        let missing = await WorkoutPhysiology.zoneMinutes(reader: reader, from: 1, to: 100, zoneSet: zones)
        XCTAssertNil(missing)
        let reversed = await WorkoutPhysiology.buckets(reader: reader, from: 100, to: 1)
        XCTAssertTrue(reversed.isEmpty)
        XCTAssertEqual(WorkoutPhysiology.deviceIds(source: "manual", activeStrapId: "active", importedIds: ["active", "my-whoop"]), ["active", "my-whoop"])
        XCTAssertEqual(WorkoutPhysiology.deviceIds(source: WorkoutSource.ouraSource, activeStrapId: "active", importedIds: ["active", "my-whoop"]), ["active", "my-whoop", WorkoutSource.ouraSource])
    }
}
