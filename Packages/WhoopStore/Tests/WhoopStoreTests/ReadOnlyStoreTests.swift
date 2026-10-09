import XCTest
import Foundation
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class ReadOnlyStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMissingFileIsNotCreated() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("absent.sqlite").path
        XCTAssertThrowsError(try WhoopStore.readOnly(path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testDoesNotMigrateOrAdoptAnOldSchema() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("old.sqlite").path
        do {
            let queue = try DatabaseQueue(path: path)
            try queue.write { try $0.execute(sql: "CREATE TABLE marker (value INTEGER)") }
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let read = try WhoopStore.readOnly(path: path)
        let tables = try read.registryWriter.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertEqual(tables, ["marker"])
        XCTAssertThrowsError(try read.registryWriter.write {
            try $0.execute(sql: "INSERT INTO marker VALUES (1)")
        })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    func testWALAndSharedResolverAgreeForVariableDriftAndWindowWidths() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let writer = try await WhoopStore(path: path)
        try await writer.upsertDevice(id: "strap", mac: nil, name: nil)
        try await writer.registryWriter.writeWithoutTransaction {
            try $0.execute(sql: "PRAGMA wal_autocheckpoint=0")
        }
        for drift in [2, 3, 5] {
            let start = 3000 + drift * 600
            let history = (0..<250).filter { !(100..<110).contains($0) }.map {
                RRInterval(ts: start + $0, rrMs: 850 + $0 % 51,
                           srcChannel: .whoop5Historical, transport: .whoopHistorical)
            }
            let standard = (0..<295).map {
                RRInterval(ts: start + $0 + drift, rrMs: 850 + $0 % 51,
                           srcChannel: .whoop5Standard, transport: .standardHeartRate)
            }
            _ = try await writer.insert(Streams(rr: history + standard), deviceId: "strap")
            let reader = try WhoopStore.readOnly(path: path)
            for width in [40, 160, 299] {
                let expected = try await writer.rrIntervals(deviceId: "strap", from: start,
                                                           to: start + width, limit: Int.max)
                let actual = try await reader.rrIntervals(deviceId: "strap", from: start,
                                                         to: start + width, limit: Int.max)
                XCTAssertEqual(actual, expected)
                XCTAssertEqual(actual.map(\.rrMs), history.filter { $0.ts <= start + width }.map(\.rrMs))
                XCTAssertTrue(actual.allSatisfy { $0.srcChannel == .whoop5Historical })
            }
        }
        let wal = try Data(contentsOf: URL(fileURLWithPath: path + "-wal"))
        XCTAssertGreaterThan(wal.count, 32, "Test must exercise uncheckpointed WAL data")
    }
    func testStandardObservationCanBePromotedOutOfItsChannelWithoutLosingHistory() async throws {
        for value in [751, 809, 922] {
            let store = try await WhoopStore.inMemory()
            try await store.upsertDevice(id: "strap", mac: nil, name: nil)
            _ = try await store.insert(Streams(rr: [
                RRInterval(ts: 3035, rrMs: value, srcChannel: .whoop5Standard,
                           transport: .standardHeartRate),
            ]), deviceId: "strap")
            _ = try await store.insert(Streams(rr: [
                RRInterval(ts: 3034, rrMs: value, srcChannel: .whoop5Historical,
                           transport: .whoopHistorical),
                RRInterval(ts: 3035, rrMs: value, srcChannel: .whoop5Historical,
                           transport: .whoopHistorical),
            ]), deviceId: "strap")
            let rows = try await store.rawRrIntervals(deviceId: "strap", from: 3030, to: 3040, limit: 100)
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { $0.srcChannel == .whoop5Historical })
            // The former BLE row retains its transport but has the history label.
            XCTAssertEqual(rows.last?.transport, .standardHeartRate)
            let selected = try await store.rrIntervals(deviceId: "strap", from: 3030, to: 3040, limit: 100)
            XCTAssertEqual(selected, rows)
        }
    }

}
