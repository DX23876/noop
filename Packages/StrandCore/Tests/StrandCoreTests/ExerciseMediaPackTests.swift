import XCTest
import Foundation
import ZIPFoundation
import StrandCore

final class ExerciseMediaPackTests: XCTestCase {
    private let provider = ExerciseMediaPack.Provider(id: "synthetic", version: "v1",
        source: URL(string: "https://example.invalid/synthetic.zip")!, attribution: "Synthetic test data",
        rightsStatus: "Synthetic", approximateBytes: 3)
    private func archive(_ root: URL, name: String, paths: [String], payload: Data = Data("abc".utf8), type: Entry.EntryType = .file) throws -> URL {
        let file = root.appendingPathComponent(name)
        let zip = try Archive(url: file, accessMode: .create)
        for path in paths {
            try zip.addEntry(with: path, type: type, uncompressedSize: UInt32(payload.count), compressionMethod: .none) { offset, count in
                payload.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        return file
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testInstallKeepsProvenanceAndResolvesOpaqueIdsToThePreferredRendition() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let zip = try archive(root, name: "pack.zip", paths: ["source/images/0001-token.jpg", "source/videos/0001-token.gif"])
        let installed = root.appendingPathComponent("installed")
        _ = try ExerciseMediaPack.install(archive: zip, provider: provider, root: installed)
        let active = installed.appendingPathComponent("v1")
        let manifest = try XCTUnwrap(ExerciseMediaPack.manifest(versionDirectory: active))
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.source, provider.source.absoluteString)
        XCTAssertEqual(manifest.attribution, provider.attribution)
        XCTAssertEqual(manifest.files.first?.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let index = ExerciseMediaPack.Index(versionDirectory: active)
        XCTAssertEqual(index.url(mediaId: "token")?.lastPathComponent, "0001-token.gif")
        XCTAssertEqual(index.url(mediaId: "token", preferStill: true)?.lastPathComponent, "0001-token.jpg")
        XCTAssertNil(index.url(mediaId: "missing"))
    }

    func testBadChecksumOversizeAndUnsafeFilesPreserveThePreviousPack() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let good = try archive(root, name: "good.zip", paths: ["source/images/good.gif"])
        let installed = root.appendingPathComponent("installed")
        _ = try ExerciseMediaPack.install(archive: good, provider: provider, root: installed)
        let manifestPath = installed.appendingPathComponent("v1/manifest.json")
        let before = try Data(contentsOf: manifestPath)
        var checked = provider; checked.expectedSHA256 = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try ExerciseMediaPack.install(archive: good, provider: checked, root: installed))
        XCTAssertThrowsError(try ExerciseMediaPack.install(archive: good, provider: provider, root: installed, limits: .init(media: 2)))
        for path in ["source/images/../escape.gif", "source/images/C:\\escape.gif"] {
            let bad = try archive(root, name: UUID().uuidString + ".zip", paths: [path])
            XCTAssertThrowsError(try ExerciseMediaPack.install(archive: bad, provider: provider, root: installed))
        }
        let link = try archive(root, name: "link.zip", paths: ["source/images/link"], type: .symlink)
        XCTAssertThrowsError(try ExerciseMediaPack.install(archive: link, provider: provider, root: installed))
        XCTAssertEqual(try Data(contentsOf: manifestPath), before)
    }

    func testCrcFailureAndDuplicateDestinationsNeverActivatePartialFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("synthetic-distinct-content".utf8)
        let corrupt = try archive(root, name: "corrupt.zip", paths: ["source/videos/test.gif"], payload: payload)
        var bytes = try Data(contentsOf: corrupt)
        let range = try XCTUnwrap(bytes.range(of: payload)); bytes[range.lowerBound] ^= 1
        try bytes.write(to: corrupt)
        let installed = root.appendingPathComponent("installed")
        XCTAssertThrowsError(try ExerciseMediaPack.install(archive: corrupt, provider: provider, root: installed))
        let duplicate = try archive(root, name: "duplicate.zip", paths: ["source/images/one/a.gif", "source/images/two/A.gif"])
        XCTAssertThrowsError(try ExerciseMediaPack.install(archive: duplicate, provider: provider, root: installed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("v1").path))
    }

    func testCancellationAndFreeSpaceOverflowCannotActivateAPack() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let zip = try archive(root, name: "cancel.zip", paths: ["source/images/test.gif"])
        let gate = AsyncStream<Void>.makeStream()
        let installed = root.appendingPathComponent("installed")
        let provider = provider
        let task = Task {
            for await _ in gate.stream {}
            return try ExerciseMediaPack.install(archive: zip, provider: provider, root: installed)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("a cancelled installer must not publish") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("v1").path))
        XCTAssertFalse(ExerciseMediaPack.hasRoom(forUncompressedBytes: Int64.max, availableBytes: Int64.max))
        XCTAssertTrue(ExerciseMediaPack.hasRoom(forUncompressedBytes: 140_000_000, availableBytes: 260_000_000))
    }
}
