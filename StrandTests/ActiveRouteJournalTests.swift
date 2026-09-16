import XCTest
@testable import Strand

/// The route of a workout in progress survives the app being terminated: points are appended in batches
/// and read back on restore, and a damaged last line never breaks the rest.
final class ActiveRouteJournalTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-journal-\(UUID().uuidString)")
            .appendingPathComponent("route.txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testBatchesAppendAndReadBackInOrder() {
        let journal = ActiveRouteJournal(url: url)
        journal.append([.init(47.3769, 8.5417), .init(47.3770, 8.5420)])
        journal.append([.init(47.3772, 8.5424)])
        XCTAssertEqual(journal.load(), [.init(47.3769, 8.5417), .init(47.3770, 8.5420), .init(47.3772, 8.5424)])
    }

    func testAPartialOrInvalidLineIsSkippedAndClearRemovesTheJournal() throws {
        let journal = ActiveRouteJournal(url: url)
        journal.append([.init(47.1, 8.1)])
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("91.0,8.2\n47.2,".utf8))
        try handle.close()
        XCTAssertEqual(journal.load(), [.init(47.1, 8.1)])
        journal.clear()
        XCTAssertEqual(journal.load(), [])
    }
}
