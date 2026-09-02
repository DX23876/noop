import XCTest
@testable import StrandAnalytics

/// Byte-identical oracle against the Kotlin `liveInsertFailedLine`. The expected strings are the exact
/// ones `StalledLinkDiagnosticsTest` pins on the Android side, so a one-sided wording change fails here
/// rather than drifting apart in the two field logs these are meant to be read beside each other.
final class LivePersistTraceTests: XCTestCase {
    func testStandardHRHostReceiptSeparatesAcceptedAndRejectedRows() {
        XCTAssertEqual(
            LivePersistTrace.standardHRHostReceivedLine(
                hostUnixSeconds: 1_750_000_000,
                acceptedHRRows: 1, acceptedRRRows: 2,
                rejectedHRRows: 0, rejectedRRRows: 1,
                pendingHRRows: 4, pendingRRRows: 5
            ),
            "standard-hr transport host-received hostUnixSec=1750000000"
                + " acceptedHRRows=1 acceptedRRRows=2 rejectedHRRows=0 rejectedRRRows=1"
                + " pendingHRRows=4 pendingRRRows=5"
        )
    }

    func testStandardHRFlushSuccessSeparatesOfferedFromActuallyInsertedRows() {
        XCTAssertEqual(
            LivePersistTrace.standardHRFlushAttemptLine(
                reason: .cadence, offeredHRRows: 4, offeredRRRows: 5
            ),
            "standard-hr transport flush-attempt reason=cadence offeredHRRows=4 offeredRRRows=5"
        )
        XCTAssertEqual(
            LivePersistTrace.standardHRFlushSucceededLine(
                reason: .cadence, offeredHRRows: 4, offeredRRRows: 5,
                insertedHRRows: 1, insertedRRRows: 2
            ),
            "standard-hr transport flush-succeeded reason=cadence offeredHRRows=4 offeredRRRows=5"
                + " insertedHRRows=1 insertedRRRows=2"
        )
    }

    func testStandardHRRetryNamesLifecycleReasonAndTotalPendingRows() {
        XCTAssertEqual(
            LivePersistTrace.standardHRRebufferedForRetryLine(
                reason: .disconnect, attemptedHRRows: 1, attemptedRRRows: 2,
                pendingHRRows: 3, pendingRRRows: 4, consecutiveFailures: 1
            ),
            "standard-hr transport rebuffered-for-retry reason=disconnect"
                + " attemptedHRRows=1 attemptedRRRows=2 pendingHRRows=3 pendingRRRows=4"
                + " consecutiveFailures=1"
        )
    }

    func testStandardHRLifecycleRouteFlushesBackgroundAndTermination() async {
        var reasons: [LivePersistTrace.StandardHRFlushReason] = []

        await StandardHRLifecycleFlush.run(event: .background) { reasons.append($0) }
        await StandardHRLifecycleFlush.run(event: .termination) { reasons.append($0) }

        XCTAssertEqual(reasons.map(\.rawValue), ["background", "termination"])
    }

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
