import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// The Training load page's "Are these the same session?" answer on Android (`training.decidePair`): the same pair
/// decisions and user links iOS's `Repository.decideTrainingSessionPair` writes.
final class CoreTrainingPairTests: XCTestCase {
    func testMergeLinksTheRecordsAndKeepSeparateOnlyRecordsTheDecision() async throws {
        let store = try await WhoopStore.inMemory()
        let merged = await CoreTrainingLoad.decidePair(store: store, ids: ["b", "a"], merge: true, now: 100)
        XCTAssertTrue(merged)
        let decisions = try await store.trainingSessionPairDecisions()
        XCTAssertEqual(decisions.map { [$0.leftKey, $0.rightKey, $0.decision] }, [["a", "b", "merge"]])
        let links = try await store.trainingSessionLinks()
        XCTAssertEqual(Set(links.map(\.componentKey)), ["a", "b"])
        XCTAssertEqual(Set(links.map(\.sessionId)), ["session|a"])

        let kept = await CoreTrainingLoad.decidePair(store: store, ids: ["c", "d"], merge: false, now: 200)
        XCTAssertTrue(kept)
        let after = try await store.trainingSessionPairDecisions()
        XCTAssertTrue(after.contains { $0.leftKey == "c" && $0.rightKey == "d" && $0.decision == "separate" })
        let linksAfter = try await store.trainingSessionLinks()
        XCTAssertEqual(linksAfter.count, 2)

        let single = await CoreTrainingLoad.decidePair(store: store, ids: ["e"], merge: true)
        XCTAssertFalse(single)
    }
}
