import XCTest
@testable import WhoopStore

/// `lowerCursor` and `removeCursor(_:ifEqualTo:)` carry a "re-price from here" debt between an analysis pass
/// and the energy refresh that settles it. Lowering must never move the debt later, and settling must not
/// drop a debt that grew while the refresh ran.
final class CursorConditionalWriteTests: XCTestCase {

    func testLoweringCreatesThenOnlyEverMovesEarlier() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.lowerCursor("debt", to: 500)
        try await store.lowerCursor("debt", to: 900)
        let afterLater = try await store.cursor("debt")
        XCTAssertEqual(afterLater, 500)
        try await store.lowerCursor("debt", to: 200)
        let afterEarlier = try await store.cursor("debt")
        XCTAssertEqual(afterEarlier, 200)
    }

    func testRemovalLeavesAValueThatMovedMeanwhile() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.setCursor("debt", 500)
        try await store.lowerCursor("debt", to: 300)
        try await store.removeCursor("debt", ifEqualTo: 500)
        let kept = try await store.cursor("debt")
        XCTAssertEqual(kept, 300)
        try await store.removeCursor("debt", ifEqualTo: 300)
        let removed = try await store.cursor("debt")
        XCTAssertNil(removed)
    }
}
