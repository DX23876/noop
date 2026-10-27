import XCTest
import GRDB
@testable import WhoopStore

/// The Android input lanes (parity plan 1.3): a complete legacy snapshot is staged and adopted once, Kotlin's
/// computed rows stay behind, existing core rows win, and later writes and deletes mirror exactly.
final class HostInputLanesTests: XCTestCase {
    private func row(_ values: [String: Any]) -> WhoopStore.LaneRow {
        values.mapValues { value -> WhoopStore.LaneValue in
            switch value {
            case let v as Int: return .integer(Int64(v))
            case let v as Double: return .real(v)
            case let v as String: return .text(v)
            default: return .null
            }
        }
    }

    func testAdoptionKeepsInputsAndSkipsComputedRows() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-10-01", key: "weight", value: 101)], deviceId: "health-connect")
        try await store.resetAndroidInputLaneStage()
        try await store.stageAndroidInputLane(table: "metricSeries", rows: [
            row(["deviceId": "health-connect", "day": "2026-10-01", "key": "weight", "value": 99.0]),
            row(["deviceId": "health-connect", "day": "2026-10-02", "key": "weight", "value": 0.0]),
            row(["deviceId": "my-whoop-noop", "day": "2026-10-02", "key": "vitality", "value": 40.0]),
            row(["deviceId": "hydration", "day": "2026-10-02", "key": "hydration", "value": 500.0]),
        ])
        try await store.stageAndroidInputLane(table: "sleepSession", rows: [
            row(["deviceId": "my-whoop-noop", "startTs": 1_000, "endTs": 2_000, "userEdited": 1]),
            row(["deviceId": "my-whoop-noop", "startTs": 5_000, "endTs": 9_000, "userEdited": 0]),
        ])
        let ownedBefore = try await store.ownsAndroidInputLanes()
        XCTAssertFalse(ownedBefore)
        try await store.commitAndroidInputLanes(replace: false)
        let ownedAfter = try await store.ownsAndroidInputLanes()
        XCTAssertTrue(ownedAfter)

        let weights = try await store.metricSeries(deviceId: "health-connect", key: "weight", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(weights.map(\.value), [101, 0])
        let computed = try await store.metricSeries(deviceId: "my-whoop-noop", key: "vitality", from: "2026-01-01", to: "2026-12-31")
        let water = try await store.metricSeries(deviceId: "hydration", key: "hydration", from: "2026-01-01", to: "2026-12-31")
        XCTAssertTrue(computed.isEmpty)
        XCTAssertTrue(water.isEmpty)
        let nights = try await store.syncRead { db in try Int.fetchAll(db, sql: "SELECT startTs FROM sleepSession ORDER BY startTs") }
        XCTAssertEqual(nights, [1_000])
    }

    func testMirrorPutsAndDeletesOnlyKnownColumns() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.putAndroidInputLaneRows(table: "workout", rows: [
            row(["deviceId": "health-connect", "startTs": 100, "endTs": 200, "sport": "Running", "source": "health-connect"]),
            row(["deviceId": "health-connect", "startTs": 300, "endTs": 400, "sport": "Running", "source": "health-connect"]),
        ])
        do {
            try await store.putAndroidInputLaneRows(table: "workout", rows: [row(["deviceId": "x", "routePolyline": "abc"])])
            XCTFail("an unknown column must be refused")
        } catch WhoopStore.InputLaneError.unknownColumn(let column) { XCTAssertEqual(column, "routePolyline") }
        do {
            try await store.putAndroidInputLaneRows(table: "hrSample", rows: [])
            XCTFail("a table outside the lanes must be refused")
        } catch WhoopStore.InputLaneError.unknownTable {}
        let removed = try await store.deleteAndroidInputLaneRows(table: "workout",
            equals: ["deviceId": .text("health-connect"), "sport": .text("Running")],
            range: ("startTs", .integer(0), .integer(250)))
        XCTAssertEqual(removed, 1)
        let left = try await store.syncRead { db in try Int.fetchAll(db, sql: "SELECT startTs FROM workout") }
        XCTAssertEqual(left, [300])
    }
}
