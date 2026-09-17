import XCTest
import StrandAnalytics
@testable import Strand

/// `SleepModel.alignedMotion` — trims a fragment's persisted motion (gridded from its DETECTED start) to
/// the window the night now shows after a hand edit moved `effectiveStartTs` / `endTs`.
///
/// Without this, a corrected onset or wake left the motion strip wider than the stage timeline above it:
/// the trace kept drawing epochs for time the night no longer claims, so restless bursts landed under the
/// wrong stages. (Grilling-session Q8b.)
final class SleepModelAlignedMotionTests: XCTestCase {
    private let epochS = Int(SleepStager.epochS)  // 30

    func testUneditedWindowIsUnchanged() {
        let epochs = (0..<10).map(Double.init)
        let aligned = SleepModel.alignedMotion(epochs, detectedStartTs: 0, effectiveStartTs: 0,
                                               endTs: 10 * 30)
        XCTAssertEqual(aligned, epochs)
    }

    func testOnsetMovedLaterTrimsTheLeadingEpochs() {
        // Detected start 0, corrected onset 2 epochs (60s) later: the first 2 epochs describe time before
        // the night now claims to have started, and must be dropped.
        let epochs = (0..<10).map(Double.init)
        let aligned = SleepModel.alignedMotion(epochs, detectedStartTs: 0, effectiveStartTs: 2 * epochS,
                                               endTs: 10 * epochS)
        XCTAssertEqual(aligned, Array(epochs[2...]))
    }

    func testWakeMovedEarlierTrimsTheTrailingEpochs() {
        let epochs = (0..<10).map(Double.init)
        let aligned = SleepModel.alignedMotion(epochs, detectedStartTs: 0, effectiveStartTs: 0,
                                               endTs: 6 * epochS)
        XCTAssertEqual(aligned, Array(epochs[0..<6]))
    }

    func testOnsetMovedEarlierIsNotPaddedWithFabricatedZeros() {
        // There is no real motion sample for time before the DETECTED start, so an onset moved earlier
        // than detection must not backfill with zeros (which would draw a fabricated "still sleeper").
        let epochs = (0..<10).map(Double.init)
        let aligned = SleepModel.alignedMotion(epochs, detectedStartTs: 5 * epochS, effectiveStartTs: 0,
                                               endTs: 15 * epochS)
        XCTAssertEqual(aligned, epochs, "no epochs to trim from the front, and none fabricated")
    }

    func testBothEdgesMovedInTrimsBothSides() {
        let epochs = (0..<10).map(Double.init)
        let aligned = SleepModel.alignedMotion(epochs, detectedStartTs: 0, effectiveStartTs: 2 * epochS,
                                               endTs: 8 * epochS)
        XCTAssertEqual(aligned, Array(epochs[2..<8]))
    }

    func testDegenerateWindowReturnsEmpty() {
        let epochs = (0..<10).map(Double.init)
        XCTAssertEqual(SleepModel.alignedMotion(epochs, detectedStartTs: 0, effectiveStartTs: 100 * epochS,
                                                endTs: 50 * epochS), [])
        XCTAssertEqual(SleepModel.alignedMotion([], detectedStartTs: 0, effectiveStartTs: 0,
                                                endTs: 10 * epochS), [])
    }

    func testLeadBeyondEpochCountReturnsEmptyRatherThanCrashing() {
        let epochs = (0..<3).map(Double.init)
        XCTAssertEqual(SleepModel.alignedMotion(epochs, detectedStartTs: 0, effectiveStartTs: 50 * epochS,
                                                endTs: 60 * epochS), [])
    }
}
