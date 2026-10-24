import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore

/// The core's dependency set links and runs: a store opens and migrates and an analytics call answers.
/// On Android this is the first thing that breaks when a dependency stops building there.
final class StrandCoreLinkTests: XCTestCase {
    func testStoreMigratesAndAnalyticsAnswersThroughTheCore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await WhoopStore(path: dir.appendingPathComponent("core.sqlite").path)
        XCTAssertFalse(RecoveryScorer.band(80).isEmpty)
    }
}
