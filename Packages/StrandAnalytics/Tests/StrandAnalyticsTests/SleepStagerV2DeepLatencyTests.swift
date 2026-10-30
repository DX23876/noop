import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The deep-latency guard: descent into N3 runs through N1 and N2, so `SleepStagerV2` holds deep back for the
/// first minutes after sleep onset, the same way it holds REM back for the first hour. From ayiskakov/noop.
final class SleepStagerV2DeepLatencyTests: XCTestCase {

    func testGuardShape() {
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(0), 3.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(10), 1.5, accuracy: 1e-12)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(20), 0.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(45), 0.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(-90), 3.0, "a pre-onset epoch is never penalised past onset's")
    }

    func testConstantsArePinned() {
        XCTAssertEqual(SleepStagerV2.deepLatencyPenalty, 3.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyMinutes, 20.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyPenalty, SleepStagerV2.remLatencyPenalty,
                       "the deep guard takes the REM guard's magnitude")
    }
}
