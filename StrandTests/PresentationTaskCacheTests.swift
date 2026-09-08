import XCTest
@testable import Strand

@MainActor
final class PresentationTaskCacheTests: XCTestCase {
    @MainActor private final class Read {
        let started = XCTestExpectation(description: "read started")
        var continuation: CheckedContinuation<Int, Error>?
        var count = 0
        func load() async throws -> Int {
            count += 1
            return try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func finish(_ value: Int) { continuation?.resume(returning: value); continuation = nil }
    }

    func testConcurrentConsumersShareOneReadAndCompletedValue() async throws {
        let cache = PresentationTaskCache<String, Int>()
        let read = Read()
        let first = Task { try await cache.value(for: "night") { try await read.load() } }
        await fulfillment(of: [read.started], timeout: 2)
        let joined = expectation(description: "second consumer joined")
        let second = Task {
            joined.fulfill()
            return try await cache.value(for: "night") { XCTFail("duplicate read"); return -1 }
        }
        await fulfillment(of: [joined], timeout: 2)
        read.finish(42)
        let results = try await (first.value, second.value)
        XCTAssertEqual(results.0, 42)
        XCTAssertEqual(results.1, 42)
        let hit = try await cache.value(for: "night") { XCTFail("cache missed"); return -1 }
        XCTAssertEqual(hit, 42)
        XCTAssertEqual(read.count, 1)
    }

    func testCancelledConsumerDoesNotCancelAnotherCardsRead() async throws {
        let cache = PresentationTaskCache<String, Int>()
        let read = Read()
        let first = Task { try await cache.value(for: "night") { try await read.load() } }
        await fulfillment(of: [read.started], timeout: 2)
        let joined = expectation(description: "second consumer joined")
        let second = Task {
            joined.fulfill()
            return try await cache.value(for: "night") { XCTFail("duplicate read"); return -1 }
        }
        await fulfillment(of: [joined], timeout: 2)
        first.cancel()
        read.finish(7)
        do { _ = try await first.value; XCTFail("cancelled consumer returned data") }
        catch is CancellationError { }
        let result = try await second.value
        XCTAssertEqual(result, 7)
        let hit = try await cache.value(for: "night") { XCTFail("successful data discarded"); return -1 }
        XCTAssertEqual(hit, 7)
    }

    func testInvalidationRejectsLateResultsForAllWaitersAndKeepsNewRevision() async throws {
        let cache = PresentationTaskCache<String, Int>()
        let oldRead = Read()
        let first = Task { try await cache.value(for: "night") { try await oldRead.load() } }
        await fulfillment(of: [oldRead.started], timeout: 2)
        let joined = expectation(description: "second consumer joined")
        let second = Task {
            joined.fulfill()
            return try await cache.value(for: "night") { XCTFail("duplicate read"); return -1 }
        }
        await fulfillment(of: [joined], timeout: 2)
        cache.invalidate()
        let corrected = try await cache.value(for: "night") { 99 }
        // Simulate a database operation that completed even though cancellation was requested.
        oldRead.finish(1)
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("stale result escaped invalidation") }
            catch is CancellationError { }
        }
        XCTAssertEqual(corrected, 99)
        let hit = try await cache.value(for: "night") { XCTFail("old read replaced new data"); return -1 }
        XCTAssertEqual(hit, 99)
    }

    func testFailedReadsCanBeRetried() async throws {
        enum Failure: Error { case injected }
        let cache = PresentationTaskCache<Int, Int>()
        do { _ = try await cache.value(for: 0) { throw Failure.injected }; XCTFail("expected error") }
        catch Failure.injected { }
        let retry = try await cache.value(for: 0) { 5 }
        XCTAssertEqual(retry, 5)
    }
}
