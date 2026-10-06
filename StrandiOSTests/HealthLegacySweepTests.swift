import XCTest
@testable import NOOP_Staging

/// The legacy sweep in `HealthSampleWriter.save` reads every NOOP sample of a type in the save window.
/// It is skipped for a day once a window came back clean, never for a window reaching further back.
final class HealthLegacySweepTests: XCTestCase {
    private let day = HealthSampleWriter.legacyRecheckSeconds

    func testNoRecordMeansSweep() {
        XCTAssertFalse(HealthSampleWriter.canSkipLegacyCheck(clean: nil, windowStart: 1_000, now: 2_000))
        XCTAssertFalse(HealthSampleWriter.canSkipLegacyCheck(clean: [1_000], windowStart: 1_000, now: 2_000))
    }

    func testAWindowInsideTheCleanSpanIsSkippedWithinTheDay() {
        let clean = [10_000.0, 50_000.0]
        XCTAssertTrue(HealthSampleWriter.canSkipLegacyCheck(clean: clean, windowStart: 10_000, now: 50_000 + day - 1))
        XCTAssertTrue(HealthSampleWriter.canSkipLegacyCheck(clean: clean, windowStart: 40_000, now: 60_000))
    }

    func testAnOlderWindowStillSweeps() {
        XCTAssertFalse(HealthSampleWriter.canSkipLegacyCheck(clean: [10_000, 50_000], windowStart: 9_999, now: 60_000))
    }

    func testTheRecordExpiresAfterADayOrWhenTheClockGoesBack() {
        XCTAssertFalse(HealthSampleWriter.canSkipLegacyCheck(clean: [10_000, 50_000], windowStart: 20_000, now: 50_000 + day))
        XCTAssertFalse(HealthSampleWriter.canSkipLegacyCheck(clean: [10_000, 50_000], windowStart: 20_000, now: 49_999))
    }

    func testACleanSweepWidensButNeverNarrowsTheSpanWithinTheDay() {
        XCTAssertEqual(HealthSampleWriter.cleanRecord(previous: nil, windowStart: 30_000, now: 50_000), [30_000, 50_000])
        XCTAssertEqual(HealthSampleWriter.cleanRecord(previous: [10_000, 50_000], windowStart: 30_000, now: 60_000), [10_000, 50_000])
        XCTAssertEqual(HealthSampleWriter.cleanRecord(previous: [10_000, 50_000], windowStart: 5_000, now: 60_000), [5_000, 50_000])
        XCTAssertEqual(HealthSampleWriter.cleanRecord(previous: [10_000, 50_000], windowStart: 30_000, now: 50_000 + day), [30_000, 50_000 + day])
    }
}
