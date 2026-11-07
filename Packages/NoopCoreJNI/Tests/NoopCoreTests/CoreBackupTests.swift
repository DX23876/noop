import XCTest
import NoopCore
import StrandCore
import WhoopStore

/// An Android backup goes through the Apple `.noopbak` path and comes back with the same rows.
final class CoreBackupTests: XCTestCase {
    func testAnExportedStoreRestoresWithTheSameDays() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("core-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = dir.appendingPathComponent("source.sqlite").path
        let source = try await WhoopStore(path: sourcePath)
        let written = try await CoreDemo.seedIfEmpty(store: source, deviceId: "my-whoop")
        XCTAssertEqual(written, CoreDemo.days)

        let backup = dir.appendingPathComponent("noop.noopbak").path
        let exported = await CoreBackup.export(store: source, dbPath: sourcePath, to: backup, scratch: dir.path,
                                               appVersion: "12.2.1", appBuild: "1")
        XCTAssertEqual(exported, .done)

        let targetPath = dir.appendingPathComponent("target.sqlite").path
        _ = try await WhoopStore(path: targetPath)   // an existing, empty store, as on a phone with the app installed
        XCTAssertEqual(CoreBackup.restore(from: backup, toDatabaseAt: targetPath, scratch: dir.path), .imported)

        let restored = try await WhoopStore(path: targetPath)
        let before = try await source.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
        let after = try await restored.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(after, before)
        let ownsInputs = try await restored.ownsAndroidJournalHydration()
        XCTAssertTrue(ownsInputs, "Restoring an archive must never replay this phone's old Room inputs")
    }

    func testAFileThatIsNoBackupIsRefusedAndTheStoreKept() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("core-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let targetPath = dir.appendingPathComponent("target.sqlite").path
        _ = try await WhoopStore(path: targetPath)
        let junk = dir.appendingPathComponent("junk.noopbak")
        try Data("not a backup".utf8).write(to: junk)
        XCTAssertEqual(CoreBackup.restore(from: junk.path, toDatabaseAt: targetPath, scratch: dir.path),
                       .failed("notSQLite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPath))
    }

    // MARK: Which strap a restored registry follows

    private let oldStrap = "AA:AA:AA:AA:AA:01", wornStrap = "BB:BB:BB:BB:BB:02"

    private func whoop(_ id: String, model: String, address: String?, status: DeviceStatus) -> PairedDevice {
        PairedDevice(id: id, brand: "WHOOP", model: model, peripheralId: address, sourceKind: .historyBLE,
                     capabilities: [], status: status, addedAt: 1, lastSeenAt: 1)
    }

    /// Backs up a store holding `backupRows`, restores it over one holding `phoneRows` and returns the restored rows.
    private func restored(backupRows: [PairedDevice], phoneRows: [PairedDevice]) async throws -> [PairedDevice] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("core-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func store(_ name: String, rows: [PairedDevice]) async throws -> (WhoopStore, String) {
            let path = dir.appendingPathComponent(name).path
            let store = try await WhoopStore(path: path)
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            if !rows.contains(where: { $0.id == "my-whoop" }) { try? registry.remove("my-whoop") }
            for row in rows { try registry.add(row) }
            return (store, path)
        }
        let (source, sourcePath) = try await store("source.sqlite", rows: backupRows)
        let backup = dir.appendingPathComponent("noop.noopbak").path
        let exported = await CoreBackup.export(store: source, dbPath: sourcePath, to: backup, scratch: dir.path,
                                               appVersion: "13.0.0", appBuild: "1")
        XCTAssertEqual(exported, .done)
        let (_, targetPath) = try await store("target.sqlite", rows: phoneRows)
        XCTAssertEqual(CoreBackup.restore(from: backup, toDatabaseAt: targetPath, scratch: dir.path), .imported)
        let after = try await WhoopStore(path: targetPath)
        return try DeviceRegistryStore(dbQueue: after.registryWriter).all()
    }

    /// The reported case: a 5.0's backup restored on a phone wearing an MG must keep following the MG.
    func testAnOldStrapsBackupKeepsTheStrapThisPhoneFollows() async throws {
        let rows = try await restored(
            backupRows: [whoop("my-whoop", model: "WHOOP 4.0", address: oldStrap, status: .active)],
            phoneRows: [whoop("my-whoop", model: "WHOOP 5.0 / MG", address: wornStrap, status: .active)])
        let row = try XCTUnwrap(rows.first { $0.id == "my-whoop" })
        XCTAssertEqual(row.peripheralId, wornStrap)
        XCTAssertEqual(row.model, "WHOOP 5.0 / MG")
        XCTAssertEqual(row.status, .active)
    }

    func testARestoredRowForTheWornStrapBecomesActive() async throws {
        let rows = try await restored(
            backupRows: [whoop("whoop-old", model: "WHOOP 5.0", address: oldStrap, status: .active),
                         whoop("whoop-mg", model: "WHOOP MG", address: wornStrap.lowercased(), status: .paired)],
            phoneRows: [whoop("my-whoop", model: "WHOOP MG", address: wornStrap, status: .active)])
        XCTAssertEqual(rows.filter { $0.status == .active }.map(\.id), ["whoop-mg"])
        XCTAssertEqual(rows.first { $0.id == "whoop-old" }?.peripheralId, oldStrap, "the old strap's row stays intact")
    }

    func testAPhoneFollowingNoStrapLetsALoneRestoredWhoopAdoptTheNextOne() async throws {
        let rows = try await restored(
            backupRows: [whoop("my-whoop", model: "WHOOP 5.0", address: oldStrap, status: .active)],
            phoneRows: [whoop("my-whoop", model: "WHOOP", address: nil, status: .active)])
        XCTAssertNil(rows.first { $0.id == "my-whoop" }?.peripheralId)
    }

    func testAPhoneFollowingNoStrapLeavesSeveralRestoredWhoopsAlone() async throws {
        let rows = try await restored(
            backupRows: [whoop("whoop-a", model: "WHOOP 5.0", address: oldStrap, status: .active),
                         whoop("whoop-b", model: "WHOOP MG", address: wornStrap, status: .paired)],
            phoneRows: [whoop("my-whoop", model: "WHOOP", address: nil, status: .active)])
        XCTAssertEqual(rows.first { $0.id == "whoop-a" }?.peripheralId, oldStrap)
        XCTAssertEqual(rows.first { $0.id == "whoop-b" }?.peripheralId, wornStrap)
    }

    /// #42: an Android backup lands beside the seeded `my-whoop`, both active. The worn strap's row stays the one
    /// active device and the empty seed, which no strap ever used, leaves the Devices list.
    func testAnEmptySeededWhoopBesideTheWornStrapLeavesTheRegistry() async throws {
        let rows = try await restored(
            backupRows: [whoop("my-whoop", model: "WHOOP", address: nil, status: .active),
                         whoop("whoop-5AG", model: "5.0 MG", address: wornStrap, status: .active)],
            phoneRows: [whoop("whoop-5AG", model: "5.0 MG", address: wornStrap, status: .active)])
        XCTAssertEqual(rows.filter { $0.status == .active }.map(\.id), ["whoop-5AG"])
        XCTAssertNil(rows.first { $0.id == "my-whoop" })
    }

    func testTwoActiveRestoredDevicesBecomeOneOnAPhoneFollowingNoStrap() async throws {
        let rows = try await restored(
            backupRows: [whoop("my-whoop", model: "WHOOP", address: nil, status: .active),
                         whoop("whoop-a", model: "WHOOP 5.0", address: oldStrap, status: .active)],
            phoneRows: [whoop("my-whoop", model: "WHOOP", address: nil, status: .active)])
        XCTAssertEqual(rows.map(\.id), ["whoop-a"])
        XCTAssertEqual(rows.first?.status, .active)
        XCTAssertNil(rows.first?.peripheralId, "the one WHOOP left adopts the next strap it meets")
    }
}
