import XCTest
@testable import StrandCore

/// The Roadmap page's parser and cache. Two files arrive over the network and may have been written by
/// a much later generator than the installed app, so the cases here are mostly about what the app does
/// with a file it does not fully understand: show what it can, drop the rest, never fail the page.
final class ProjectFeedTests: XCTestCase {

    private let roadmapJSON = """
    {"schema": 1, "items": [
      {"id": "a", "phase": "now", "title": "First", "line": "One.", "icon": "sparkles",
       "area": "app", "since": "2026-11-01"},
      {"id": "b", "phase": "now", "title": "Second", "line": "Two.", "icon": "flame.fill",
       "area": "cardio"},
      {"id": "c", "phase": "later", "title": "Third", "line": "Three.", "icon": "iphone",
       "area": "body"}
    ]}
    """.data(using: .utf8)!

    private let feedJSON = """
    {"schema": 1, "generated": "2026-11-15T12:00:00Z", "service": null,
     "counts": {"reported": 2, "working": 1, "fixed": 1},
     "issues": [{"n": 48, "title": "Syncing bar stops", "status": "reported", "opened": "2026-11-10"},
                {"n": 46, "title": "Sync loop", "status": "working", "opened": "2026-11-09"}],
     "fixed": [{"n": 39, "title": "Package appears invalid", "status": "fixed",
                "closed": "2026-11-01", "fixedIn": "2.1.1"}],
     "decided": [{"n": 30, "title": "Watch face", "status": "notPlanned", "closed": "2026-11-05"}]}
    """.data(using: .utf8)!

    // MARK: Roadmap

    func testRoadmapKeepsFileOrderWithinAPhase() {
        let items = ProjectFeedParser.roadmap(from: roadmapJSON)
        XCTAssertEqual(items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(items.filter { $0.phase == .now }.map(\.id), ["a", "b"])
    }

    func testSinceIsKeptOnlyOnAnItemBeingWorkedOn() {
        let items = ProjectFeedParser.roadmap(from: roadmapJSON)
        XCTAssertEqual(items[0].since, "2026-11-01")
        let later = """
        {"items": [{"id": "x", "phase": "later", "title": "T", "line": "L", "icon": "i",
                    "area": "app", "since": "2026-11-01"}]}
        """.data(using: .utf8)!
        XCTAssertNil(ProjectFeedParser.roadmap(from: later).first?.since)
    }

    func testAnUnknownPhaseOrAreaDropsOnlyThatItem() {
        let mixed = """
        {"items": [{"id": "ok", "phase": "now", "title": "T", "line": "L", "icon": "i", "area": "app"},
                   {"id": "futurePhase", "phase": "someday", "title": "T", "line": "L", "icon": "i",
                    "area": "app"},
                   {"id": "futureArea", "phase": "now", "title": "T", "line": "L", "icon": "i",
                    "area": "mind"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(ProjectFeedParser.roadmap(from: mixed).map(\.id), ["ok"])
    }

    func testADuplicateIdIsIgnoredRatherThanDrawnTwice() {
        let twice = """
        {"items": [{"id": "a", "phase": "now", "title": "One", "line": "L", "icon": "i", "area": "app"},
                   {"id": "a", "phase": "next", "title": "Two", "line": "L", "icon": "i", "area": "app"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(ProjectFeedParser.roadmap(from: twice).map(\.title), ["One"])
    }

    func testNonsenseIsAnEmptyRoadmapAndNotACrash() {
        XCTAssertEqual(ProjectFeedParser.roadmap(from: Data("not json".utf8)).count, 0)
        XCTAssertEqual(ProjectFeedParser.roadmap(from: Data()).count, 0)
    }

    // MARK: Text

    func testTitlesLoseControlCharactersAndExtraWhitespace() {
        XCTAssertEqual(ProjectFeedParser.clamp("Sync\u{0007}  stops\nhere", limit: 120), "Sync stops here")
    }

    func testOverLongTextIsTruncatedWithAnEllipsis() {
        let clamped = ProjectFeedParser.clamp(String(repeating: "x", count: 300), limit: 40)
        XCTAssertEqual(clamped.count, 40)
        XCTAssertTrue(clamped.hasSuffix("…"))
    }

    // MARK: Feed

    func testFeedReadsTheThreeListsAndTheGeneratedStamp() {
        let page = ProjectFeedParser.feed(from: feedJSON, fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(page.reported.map(\.number), [48, 46])
        XCTAssertEqual(page.reportedCount, 1)
        XCTAssertEqual(page.workingCount, 1)
        XCTAssertEqual(page.fixed.first?.fixedIn, "2.1.1")
        XCTAssertEqual(page.decided.first?.status, .notPlanned)
        XCTAssertEqual(page.generated,
                       ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z"))
        XCTAssertEqual(page.fetchedAt, Date(timeIntervalSince1970: 100))
    }

    func testAnUnknownStatusDropsOnlyThatRow() {
        let data = """
        {"issues": [{"n": 1, "title": "Keep", "status": "reported"},
                    {"n": 2, "title": "Drop", "status": "escalated"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(ProjectFeedParser.feed(from: data, fetchedAt: nil).reported.map(\.number), [1])
    }

    func testARowWithoutANumberOrTitleIsDropped() {
        let data = """
        {"issues": [{"title": "No number", "status": "reported"},
                    {"n": 3, "title": "   ", "status": "reported"},
                    {"n": 4, "title": "Fine", "status": "reported"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(ProjectFeedParser.feed(from: data, fetchedAt: nil).reported.map(\.number), [4])
    }

    // MARK: The service address

    func testOnlyAnHTTPSServiceAddressIsKept() {
        XCTAssertNotNil(ProjectFeedParser.service(from: "https://x.workers.dev"))
        XCTAssertNil(ProjectFeedParser.service(from: "http://x.workers.dev"))
        XCTAssertNil(ProjectFeedParser.service(from: "https://user:pass@x.workers.dev"))
        XCTAssertNil(ProjectFeedParser.service(from: "ftp://x.test"))
        XCTAssertNil(ProjectFeedParser.service(from: ""))
        XCTAssertNil(ProjectFeedParser.service(from: nil))
    }

    func testAMissingServiceMeansTheFeaturesStayHidden() {
        XCTAssertNil(ProjectFeedParser.feed(from: feedJSON, fetchedAt: nil).service)
    }

    // MARK: Store

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRefreshKeepsTheCopyItReadAndCachedReturnsIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = ProjectFeedSources(roadmap: URL(string: "https://x.test/roadmap.json")!,
                                         feed: URL(string: "https://x.test/app-feed.json")!)
        let roadmap = roadmapJSON, feed = feedJSON
        let store = ProjectPageStore(directory: directory, sources: sources) { url in
            url.lastPathComponent == "roadmap.json" ? roadmap : feed
        }
        let page = await store.refresh(now: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(page.roadmap.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(page.reported.map(\.number), [48, 46])

        let second = ProjectPageStore(directory: directory, sources: sources) { _ in
            throw ProjectFeedError.unreadable
        }
        let cached = await second.cached()
        XCTAssertEqual(cached.roadmap.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(cached.fetchedAt, Date(timeIntervalSince1970: 500))
    }

    func testAWriteReadsTheFeedWhenTheCacheHasNoAddress() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = ProjectFeedSources(roadmap: URL(string: "https://x.test/roadmap.json")!,
                                         feed: URL(string: "https://x.test/app-feed.json")!)
        let roadmap = roadmapJSON
        let feed = String(decoding: feedJSON, as: UTF8.self)
            .replacingOccurrences(of: "\"service\": null", with: "\"service\": \"https://relay.test\"")
            .data(using: .utf8)!
        let reads = ReadCount()
        let store = ProjectPageStore(directory: directory, sources: sources) { url in
            reads.add()
            return url.lastPathComponent == "roadmap.json" ? roadmap : feed
        }
        let empty = await store.cached()
        XCTAssertNil(empty.service, "nothing cached yet")
        let page = await store.forWriting(now: Date(timeIntervalSince1970: 500))
        XCTAssertNotNil(page.service, "an empty cache is read again before a write gives up")
        XCTAssertEqual(reads.value, 2, "one read of each file")
        _ = await store.forWriting(now: Date(timeIntervalSince1970: 600))
        XCTAssertEqual(reads.value, 2, "a cache that knows the address is used as it is")
    }

    func testAFailedReadShowsTheLastCopyRatherThanAnEmptyPage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = ProjectFeedSources(roadmap: URL(string: "https://x.test/roadmap.json")!,
                                         feed: URL(string: "https://x.test/app-feed.json")!)
        let roadmap = roadmapJSON, feed = feedJSON
        let good = ProjectPageStore(directory: directory, sources: sources) { url in
            url.lastPathComponent == "roadmap.json" ? roadmap : feed
        }
        _ = await good.refresh(now: Date(timeIntervalSince1970: 500))

        let offline = ProjectPageStore(directory: directory, sources: sources) { _ in
            throw ProjectFeedError.unreadable
        }
        let page = await offline.refresh(now: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(page.roadmap.map(\.id), ["a", "b", "c"], "the page fell back to the cache")
        XCTAssertEqual(page.fetchedAt, Date(timeIntervalSince1970: 500), "and kept the real read time")
    }

    func testAnEmptyAnswerNeverReplacesAGoodCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = ProjectFeedSources(roadmap: URL(string: "https://x.test/roadmap.json")!,
                                         feed: URL(string: "https://x.test/app-feed.json")!)
        let roadmap = roadmapJSON, feed = feedJSON
        let good = ProjectPageStore(directory: directory, sources: sources) { url in
            url.lastPathComponent == "roadmap.json" ? roadmap : feed
        }
        _ = await good.refresh(now: Date(timeIntervalSince1970: 500))

        let empty = ProjectPageStore(directory: directory, sources: sources) { _ in Data("{}".utf8) }
        let page = await empty.refresh(now: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(page.roadmap.map(\.id), ["a", "b", "c"])
    }

    func testTheShippedFilesParseIntoAPageWorthDrawing() throws {
        // The product source, not a fixture: the two files that actually ship must render. A unit test
        // over handwritten JSON would keep passing after someone edits the real roadmap into nonsense.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let roadmapFile = root.appendingPathComponent("docs/roadmap.json")
        let feedFile = root.appendingPathComponent("docs/app-feed.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: roadmapFile.path),
                          "run from the repository")
        let items = ProjectFeedParser.roadmap(from: try Data(contentsOf: roadmapFile))
        XCTAssertFalse(items.isEmpty, "the shipped roadmap parsed to nothing")
        XCTAssertTrue(items.contains { $0.phase == .now }, "no item is in progress")
        let page = ProjectFeedParser.feed(from: try Data(contentsOf: feedFile), fetchedAt: nil)
        XCTAssertFalse(page.reported.isEmpty && page.fixed.isEmpty,
                       "the shipped feed parsed to nothing")
    }
}

/// How many times a test's fake transport was asked for a file.
private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}
