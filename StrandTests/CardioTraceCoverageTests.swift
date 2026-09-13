import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The coverage rule that decides whether a heart-rate trace may stand for a session.
///
/// It is shared deliberately: cardio load and the time-in-zone split ask the same question of the same
/// trace, and if they answered it differently one screen would price a session the other could not show.
final class CardioTraceCoverageTests: XCTestCase {

    private static let start = 1_699_963_200
    private static let end = start + 3_600   // one hour

    /// One sample a minute across the window, for `minutes` minutes from the start.
    private func trace(minutes: Int, from offset: Int = 0) -> [HRSample] {
        (0..<minutes).map { HRSample(ts: Self.start + (offset + $0) * 60, bpm: 140) }
    }

    func testAFullTraceCoversItsWindow() {
        XCTAssertTrue(Repository.hasUsableCoverage(trace(minutes: 60), start: Self.start, end: Self.end))
    }

    /// Seventy per cent is the bar, and a trace that stops two thirds of the way through does not clear
    /// it: the missing third is training whose intensity nobody recorded.
    func testAPartialTraceIsRejected() {
        XCTAssertTrue(Repository.hasUsableCoverage(trace(minutes: 43), start: Self.start, end: Self.end))
        XCTAssertFalse(Repository.hasUsableCoverage(trace(minutes: 41), start: Self.start, end: Self.end))
    }

    /// A handful of stray readings is not a trace, however short the session.
    func testAFewStraySamplesAreNotATrace() {
        XCTAssertFalse(Repository.hasUsableCoverage(trace(minutes: 9),
                                                    start: Self.start, end: Self.start + 540))
    }

    /// Samples outside the window are not evidence about the window.
    func testSamplesOutsideTheWindowDoNotCount() {
        let outside = (0..<60).map { HRSample(ts: Self.end + 600 + $0 * 60, bpm: 140) }
        XCTAssertFalse(Repository.hasUsableCoverage(outside, start: Self.start, end: Self.end))
    }

    /// Coverage counts MINUTES, not samples: a dense burst over ten minutes does not describe an hour.
    func testCoverageCountsMinutesNotSamples() {
        let burst = (0..<600).map { HRSample(ts: Self.start + $0, bpm: 140) }
        let coverage = Repository.traceCoverage(burst, start: Self.start, end: Self.end)
        XCTAssertEqual(coverage.covered, 10)
        XCTAssertEqual(coverage.possible, 60)
        XCTAssertFalse(Repository.hasUsableCoverage(burst, start: Self.start, end: Self.end))
    }
}
