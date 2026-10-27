import XCTest
import Foundation
import ZIPFoundation
@testable import NoopCore

final class CoreExerciseMediaTests: XCTestCase {
    func testMediaLifecycleDoesNotNeedAStrapStoreAndDisablingPreservesThePack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.zip")
        let zip = try Archive(url: file, accessMode: .create)
        try zip.addEntry(with: "source/images/0001-token.gif", type: .file, uncompressedSize: Int64(3),
                         compressionMethod: .none) { offset, count in Data("abc".utf8).subdata(in: Int(offset)..<(Int(offset) + count)) }
        let media = CoreExerciseMedia()
        let initial = await media.configure(root: root, disabled: false)
        XCTAssertEqual(initial.state, "unavailable")
        let installed = await media.install(archive: file)
        XCTAssertEqual(installed.state, "ready")
        XCTAssertEqual(installed.manifest?.files.count, 1)
        let resolved = await media.resolve(mediaId: "token", still: false)
        XCTAssertEqual(resolved.map { URL(fileURLWithPath: $0).lastPathComponent }, "0001-token.gif")
        await media.setDisabled(true)
        let disabled = await media.info()
        XCTAssertEqual(disabled.state, "disabled")
        let hidden = await media.resolve(mediaId: "token", still: false)
        XCTAssertNil(hidden)
        await media.setDisabled(false)
        let enabled = await media.resolve(mediaId: "token", still: true)
        XCTAssertEqual(enabled, resolved)
        let deleted = await media.delete()
        XCTAssertTrue(deleted)
        let empty = await media.info()
        XCTAssertEqual(empty.state, "unavailable")
    }
}
