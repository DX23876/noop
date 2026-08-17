import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class LiveStateDomainTagTests: XCTestCase {

    /// Strip the sink's "[HH:mm:ss] " stamp so a test can assert the line BODY without pinning a clock.
    /// Fails (rather than silently passing the line through) when the stamp is missing, so the stamping
    /// contract itself is covered by every assertion below.
    private func unstamped(_ line: String?, file: StaticString = #filePath, line ln: UInt = #line) -> String {
        guard let line else { XCTFail("no line logged", file: file, line: ln); return "" }
        XCTAssertTrue(LiveState.hasLeadingTimestamp(line),
                      "every sink-stamped line must open with [HH:mm:ss], got \(line)", file: file, line: ln)
        return LiveState.withoutLeadingTimestamp(line)
    }

    // No domain => no tag prefix, just the sink's stamp and the body.
    func testNilDomainLeavesLineUntagged() {
        let live = LiveState()
        live.append(log: "connected ok")
        XCTAssertEqual(unstamped(live.log.last), "connected ok")
    }

    // A domain => a compact, parseable "[<id>] " marker, glued to the line body so every
    // `contains("[<id>] <body>")` reader still matches.
    func testDomainPrefixesCompactMarker() {
        let live = LiveState()
        live.append(log: "gate run kept", domain: .sleep)
        XCTAssertEqual(unstamped(live.log.last), "[sleep] gate run kept")
        XCTAssertEqual(live.taggedTail(domain: .sleep), live.log)
    }

    // dataImport uses the wire id, not the rawValue.
    func testDataImportUsesWireId() {
        let live = LiveState()
        live.append(log: "parsed 10 rows", domain: .dataImport)
        XCTAssertEqual(unstamped(live.log.last), "[import] parsed 10 rows")
    }

    // Redaction STILL runs, and it runs over the already-tagged text (the serial in the body is masked,
    // the tag is untouched).
    func testRedactionRunsAfterTagging() {
        let live = LiveState()
        live.append(log: "saw WHOOP 4C1594026 advertise", domain: .connection)
        XCTAssertEqual(unstamped(live.log.last), "[connection] saw WHOOP <serial> advertise")
    }

    // MARK: - Timestamping (so a frame hitch can be lined up against the BLE line beside it)

    /// A line that reaches the sink WITHOUT a stamp (the Display monitor's digests, the re-score line)
    /// gets one, so report.txt has no timeless lines left to correlate around.
    func testUnstampedLineIsStampedBySink() {
        let live = LiveState()
        live.append(log: "frameSummary frames=60 mean=16.7ms", domain: .display)
        XCTAssertEqual(unstamped(live.log.last), "[display] frameSummary frames=60 mean=16.7ms")
    }

    /// A caller that already stamps (BLEManager.log) must NOT be stamped twice.
    func testCallerStampedLineIsNotDoubleStamped() {
        let live = LiveState()
        live.append(log: "[09:26:51] Backfill: session ended")
        XCTAssertEqual(live.log.last, "[09:26:51] Backfill: session ended")
    }

    /// The stamp detector reads a SHAPE, not a prefix: a bracketed non-time opener is still stamped.
    func testLeadingTimestampShapeDetection() {
        XCTAssertTrue(LiveState.hasLeadingTimestamp("[00:00:00] x"))
        XCTAssertTrue(LiveState.hasLeadingTimestamp("[23:59:59]"))
        XCTAssertFalse(LiveState.hasLeadingTimestamp("[display] frameSummary"))
        XCTAssertFalse(LiveState.hasLeadingTimestamp("[9:26:51] short"))
        XCTAssertFalse(LiveState.hasLeadingTimestamp("09:26:51 no brackets"))
        XCTAssertFalse(LiveState.hasLeadingTimestamp("[ab:cd:ef] not digits"))
        XCTAssertFalse(LiveState.hasLeadingTimestamp("short"))
        XCTAssertFalse(LiveState.hasLeadingTimestamp(""))
        XCTAssertEqual(LiveState.withoutLeadingTimestamp("[00:00:00] x"), "x")
        XCTAssertEqual(LiveState.withoutLeadingTimestamp("no stamp"), "no stamp")
    }

    /// `taggedTail` reads the tag THROUGH the stamp, so the Test Centre live readouts keep seeing their
    /// domain's lines (and only theirs).
    func testTaggedTailStepsOverTheStamp() {
        let live = LiveState()
        live.append(log: "frameSummary frames=60", domain: .display)
        live.append(log: "bank soc=80.0 t=1000s", domain: .battery)
        live.append(log: "plain line")
        XCTAssertEqual(live.taggedTail(domain: .display).count, 1)
        XCTAssertEqual(live.taggedTail(domain: .battery).count, 1)
        XCTAssertTrue(live.taggedTail(domain: .sleep).isEmpty)
    }
}
