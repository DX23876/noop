import XCTest
@testable import WhoopProtocol

/// #324 — the pure strap-log formatters for a bad-clock strap. Deterministic (now is injected), so the
/// Kotlin twin (`BadClockDiagnostics` in WhoopBleClient) must produce byte-identical strings.
final class BadClockDiagnosticsTests: XCTestCase {

    func testIsoDayIsUTC() {
        // 1_735_084_800 == 2024-12-25 00:00 UTC (the #547 tests' documented badYule anchor).
        XCTAssertEqual(BadClockDiagnostics.isoDay(1_735_084_800), "2024-12-25")
    }

    func testHoursOffsetWording() {
        let now = 1_783_843_824
        XCTAssertEqual(BadClockDiagnostics.hoursOffset(now + 26_445 * 3600, now: now), "26445h ahead")
        XCTAssertEqual(BadClockDiagnostics.hoursOffset(now - 512 * 3600, now: now), "512h behind")
        XCTAssertEqual(BadClockDiagnostics.hoursOffset(now + 60, now: now), "~now")   // within an hour
    }

    func testDroppedSpanClause() {
        let now = 1_783_843_824
        // Nothing dropped → empty clause so the base sentence reads normally.
        XCTAssertEqual(BadClockDiagnostics.droppedSpanClause(oldest: nil, newest: nil, now: now), "")
        // A range → "oldest -> newest, offset(newest)". Build the expected from the same pinned primitives
        // (isoDay/hoursOffset are covered above) so the test pins the ASSEMBLY, not hand-computed dates.
        let o = 1_845_000_000, n = 1_876_000_000
        let expected = " (dated \(BadClockDiagnostics.isoDay(o)) -> \(BadClockDiagnostics.isoDay(n)), "
            + "\(BadClockDiagnostics.hoursOffset(n, now: now)))"
        XCTAssertEqual(BadClockDiagnostics.droppedSpanClause(oldest: o, newest: n, now: now), expected)
        XCTAssertTrue(expected.contains("->"))
        // oldest == newest → single date, no arrow.
        let single = BadClockDiagnostics.droppedSpanClause(oldest: n, newest: n, now: now)
        XCTAssertFalse(single.contains("->"), single)
        XCTAssertEqual(single, " (dated \(BadClockDiagnostics.isoDay(n)), \(BadClockDiagnostics.hoursOffset(n, now: now)))")
    }
}
