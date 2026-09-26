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

    func testMeasuredPointsRestoreWithTheirTimeAndAccuracy() {
        let journal = ActiveRouteJournal(url: url)
        journal.append(measured: [WorkoutRoutePoint(lat: 47.3769, lon: 8.5417, accuracyM: 4.5, tMs: 1_700_000_000_000),
                                  WorkoutRoutePoint(lat: 47.3770, lon: 8.5420, accuracyM: 6.25, tMs: 1_700_000_005_000)])
        let restored = journal.loadMeasured()
        XCTAssertEqual(restored.track, [.init(47.3769, 8.5417), .init(47.3770, 8.5420)])
        XCTAssertEqual(restored.points?.map(\.tMs), [1_700_000_000_000, 1_700_000_005_000])
        XCTAssertEqual(restored.points?.map(\.accuracyM), [4.5, 6.25])
    }

    func testABareLineRestoresTheTrackButNoMeasurements() {
        let journal = ActiveRouteJournal(url: url)
        journal.append([.init(47.1, 8.1)])
        journal.append(measured: [WorkoutRoutePoint(lat: 47.2, lon: 8.2, accuracyM: 5, tMs: 1_700_000_000_000)])
        let restored = journal.loadMeasured()
        XCTAssertEqual(restored.track, [.init(47.1, 8.1), .init(47.2, 8.2)])
        XCTAssertNil(restored.points)
    }
}
