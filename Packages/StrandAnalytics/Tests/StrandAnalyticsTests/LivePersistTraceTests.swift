import XCTest
@testable import StrandAnalytics

/// Byte-identical oracle against the Kotlin `liveInsertFailedLine`. The expected strings are the exact
/// ones `StalledLinkDiagnosticsTest` pins on the Android side, so a one-sided wording change fails here
/// rather than drifting apart in the two field logs these are meant to be read beside each other.
final class LivePersistTraceTests: XCTestCase {

    /// Two live transports fail independently (#1118), so the line must say which.
    func testNamesTheFailingTransport() {
        XCTAssertTrue(LivePersistTrace.liveInsertFailedLine(
            transport: "live-standard", errorName: "E", message: nil,
            hrFrames: 1, rrFrames: 1, consecutiveFailures: 1).contains("on live-standard"))
        XCTAssertTrue(LivePersistTrace.liveInsertFailedLine(
            transport: "live-realtime", errorName: "E", message: nil,
            hrFrames: 1, rrFrames: 1, consecutiveFailures: 1).contains("on live-realtime"))
    }

    /// One failure is the transient the re-buffer absorbs; a run is a store that will not take these rows.
    /// If both rendered the same the count would be decoration.
    func testOneFailureReadsTransientAndARunReadsAsNotRecovering() {
        let once = LivePersistTrace.liveInsertFailedLine(
            transport: "live-standard", errorName: "SQLiteFullException",
            message: "database or disk is full", hrFrames: 12, rrFrames: 13, consecutiveFailures: 1)
        XCTAssertTrue(once.contains("Re-buffered for the next cadence."))
        XCTAssertFalse(once.contains("consecutive failures"))

        let many = LivePersistTrace.liveInsertFailedLine(
            transport: "live-standard", errorName: "SQLiteFullException",
            message: "database or disk is full", hrFrames: 12, rrFrames: 13, consecutiveFailures: 9)
        XCTAssertTrue(many.contains("9 consecutive failures"))
        XCTAssertTrue(many.contains("not recovering them."))
    }

    /// Whole-line equality, not `contains`: this is the assertion that actually holds the two platforms
    /// together, since a stray space or a moved clause would still satisfy every check above.
    func testWholeLineMatchesTheKotlinRendering() {
        XCTAssertEqual(
            LivePersistTrace.liveInsertFailedLine(
                transport: "live-standard", errorName: "SQLiteFullException",
                message: "database or disk is full", hrFrames: 12, rrFrames: 13, consecutiveFailures: 9),
            "Live persist FAILED on live-standard — SQLiteFullException: database or disk is full"
                + " (hr=12 rr=13). 9 consecutive failures — these rows are not landing and the re-buffer"
                + " is not recovering them.")
        XCTAssertEqual(
            LivePersistTrace.liveInsertFailedLine(
                transport: "live-realtime", errorName: "IllegalStateException", message: nil,
                hrFrames: 0, rrFrames: 4, consecutiveFailures: 1),
            "Live persist FAILED on live-realtime — IllegalStateException (hr=0 rr=4)."
                + " Re-buffered for the next cadence.")
    }

    func testMessageSurvivesAndIsBounded() {
        let line = LivePersistTrace.liveInsertFailedLine(
            transport: "live-standard", errorName: "IllegalStateException",
            message: String(repeating: "x", count: 500), hrFrames: 1, rrFrames: 2, consecutiveFailures: 1)
        XCTAssertTrue(line.contains(String(repeating: "x", count: 200)))
        XCTAssertFalse(line.contains(String(repeating: "x", count: 201)))
    }

    func testBlankOrAbsentMessageLeavesNoDanglingSeparator() {
        for message in [nil, "   "] as [String?] {
            let line = LivePersistTrace.liveInsertFailedLine(
                transport: "live-standard", errorName: "IllegalStateException", message: message,
                hrFrames: 1, rrFrames: 2, consecutiveFailures: 1)
            XCTAssertFalse(line.contains(": ("), "a blank message must not leave a dangling colon")
        }
    }

    // MARK: - rate limit

    /// The first failure is the one most worth having, so "never emitted" must not read as "just emitted".
    func testFirstFailureAlwaysEmits() {
        XCTAssertTrue(LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: 0, nowMs: 1_000))
        XCTAssertTrue(LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: -5, nowMs: 1_000))
    }

    func testGapIsHonouredAtItsBoundary() {
        XCTAssertFalse(LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: 1_000, nowMs: 60_999))
        XCTAssertTrue(LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: 1_000, nowMs: 61_000))
    }

    /// A clock that steps backwards must not latch the line off until real time catches up.
    func testBackwardsClockEmitsRatherThanLatchingOff() {
        XCTAssertTrue(LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: 10_000, nowMs: 5_000))
        XCTAssertTrue(LivePersistTrace.shouldEmitLiveInsertFailure(
            lastEmitMs: Int64.max / 2, nowMs: 1_000))
    }
}
