import XCTest
import ZIPFoundation
@testable import StrandImport

/// The export importers must not buffer an unbounded slice of an archive in RAM. Before, each importer
/// collected every recognised entry into a `[String: Data]` with only a PER-ENTRY cap — the SUM of the
/// retained set was unbounded (the Wearable path can carry up to `maxFiles` = 200k entries). These tests
/// pin the new aggregate `maxTotalBytes` budget: once adding the next retained entry would exceed it,
/// collection stops. ZIPFoundation preserves add-order, so which entries survive is deterministic.
final class ImportByteBudgetTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("strandimport-budget-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    /// Build a zip from ordered `(entryPath, rawBytes)` pairs.
    private func makeZip(named: String, entries: [(String, Data)]) throws -> URL {
        let zipURL = makeTempDir().appendingPathComponent(named)
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let start = data.startIndex + Int(position)
                return data.subdata(in: start ..< start + size)
            }
        }
        return zipURL
    }

    // MARK: Whoop — a cap admitting only the first CSV drops the rest (end-to-end through parse)

    func testWhoopZipStopsAtTotalByteBudget() throws {
        let cycles = Fixtures.data("physiological_cycles.csv")
        let zip = try makeZip(named: "whoop.zip", entries: [
            ("physiological_cycles.csv", cycles),
            ("sleeps.csv", Fixtures.data("sleeps.csv")),
            ("workouts.csv", Fixtures.data("workouts.csv")),
            ("journal_entries.csv", Fixtures.data("journal_entries.csv")),
        ])

        // Uncapped: all four CSVs are parsed.
        let full = try WhoopExportImporter().import(from: zip)
        XCTAssertEqual(full.cycles.count, 2)
        XCTAssertEqual(full.sleeps.count, 2)
        XCTAssertEqual(full.workouts.count, 2)
        XCTAssertEqual(full.journal.count, 2)

        // Cap = just over the first (cycles) CSV: the budget trips before the second retained entry, so only
        // cycles survives — no unbounded buffering of the whole archive.
        let capped = try WhoopExportImporter(maxTotalBytes: cycles.count + 1).import(from: zip)
        XCTAssertEqual(capped.cycles.count, 2)
        XCTAssertTrue(capped.sleeps.isEmpty)
        XCTAssertTrue(capped.workouts.isEmpty)
        XCTAssertTrue(capped.journal.isEmpty)
    }

    // MARK: Wearable — the real offender: cap bounds the retained set regardless of entry count

    func testWearableZipStopsAtTotalByteBudget() throws {
        // Content is irrelevant to collection (the wellness filter is name-based); size is what matters.
        let blob = Data(repeating: 0x20, count: 400)   // 400 bytes each, all "sleep*" → wellness by name
        let zip = try makeZip(named: "wearable.zip", entries: [
            ("sleep_a.json", blob),
            ("sleep_b.json", blob),
            ("sleep_c.json", blob),
        ])

        let full = try WearableExportImporter().collectFiles(from: zip)
        XCTAssertEqual(full.count, 3)

        // Cap = 1.5 blobs: admits the first, trips before the second.
        let cap = 600
        let capped = try WearableExportImporter(maxTotalBytes: cap).collectFiles(from: zip)
        XCTAssertEqual(capped.count, 1)
        XCTAssertLessThanOrEqual(capped.values.reduce(0) { $0 + $1.count }, cap)
    }
}
