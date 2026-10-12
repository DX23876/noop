import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class MaxHRSuggestionTests: XCTestCase {

    private typealias M = MaxHRSuggestion

    /// A spike does not count; a level held for 30 seconds does; a gap breaks the hold.
    func testHeldPeak() {
        var hr = (0..<120).map { HRSample(ts: $0, bpm: 170) }
        hr[60] = HRSample(ts: 60, bpm: 205)                       // one-sample spike
        XCTAssertEqual(M.heldPeak(hr), 170)
        let held = (0..<40).map { HRSample(ts: 200 + $0, bpm: 188) }
        XCTAssertEqual(M.heldPeak(hr + held), 188)
        let broken = (0..<20).map { HRSample(ts: 400 + $0, bpm: 199) } + (0..<20).map { HRSample(ts: 430 + $0, bpm: 199) }
        XCTAssertEqual(M.heldPeak(broken), nil, "a 10 s gap splits it into two 19 s stretches")
        XCTAssertNil(M.heldPeak([]))
    }

    /// Two days at the level, five beats above the current value, newer than a declined value.
    func testSuggestion() {
        let peaks = [(day: "2026-10-01", value: 196.0), (day: "2026-09-20", value: 194.0),
                     (day: "2026-09-10", value: 201.0), (day: "2025-12-01", value: 210.0)]
        XCTAssertEqual(M.suggestion(dayPeaks: peaks, current: 185, declined: 0, today: "2026-10-12"), 196)
        XCTAssertNil(M.suggestion(dayPeaks: peaks, current: 192, declined: 0, today: "2026-10-12"))
        XCTAssertNil(M.suggestion(dayPeaks: peaks, current: 185, declined: 196, today: "2026-10-12"))
        XCTAssertNil(M.suggestion(dayPeaks: [(day: "2026-10-01", value: 199.0)], current: 185, declined: 0,
                                  today: "2026-10-12"))
    }
}
