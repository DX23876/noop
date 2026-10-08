import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class GaitGatedStepCounterTests: XCTestCase {
    /// A walk of `seconds` records at 2 ticks per second starting at `start` from `counter`, preceded by one
    /// still record so the first increment has a predecessor.
    private func walk(from start: Int, seconds: Int, counter: Int = 0, cls: Int? = 1) -> [StepSample] {
        var out = [StepSample(ts: start - 1, counter: counter, activityClass: cls == nil ? nil : 0)]
        for i in 0..<seconds {
            out.append(StepSample(ts: start + i, counter: counter + 2 * (i + 1), activityClass: cls))
        }
        return out
    }

    private func count(_ samples: [StepSample], _ start: Int = 0, _ end: Int = 100_000) -> GaitGatedStepCounter.Result {
        GaitGatedStepCounter.count(samples, windowStart: start, windowEndExclusive: end)
    }

    func testSustainedWalkIsKeptWhole() {
        let r = count(walk(from: 1_000, seconds: 40))   // 80 ticks
        XCTAssertEqual(r.sustainedTicks, 80)
        XCTAssertEqual(r.totalTicks, 80)
        XCTAssertEqual(r.legacyTicks, 80)
        XCTAssertEqual(r.rejectedShortBouts, 0)
    }

    func testIsolatedShortBoutIsRejected() {
        let r = count(walk(from: 1_000, seconds: 10))   // 20 ticks, nothing nearby
        XCTAssertEqual(r.totalTicks, 0)
        XCTAssertEqual(r.rejectedTicks, 20)
        XCTAssertEqual(r.rejectedShortBouts, 1)
        XCTAssertEqual(r.legacyTicks, 20)
    }

    func testShortBoutNearSustainedWalkIsKept() {
        let long = walk(from: 1_000, seconds: 40)                      // ends at 1039, counter 80
        let near = walk(from: 1_039 + 120, seconds: 10, counter: 80)   // 120 s later
        let far = walk(from: 1_039 + 120 + 9 + 400, seconds: 10, counter: 100)
        let r = count(long + near + far)
        XCTAssertEqual(r.sustainedTicks, 80)
        XCTAssertEqual(r.contextTicks, 20)
        XCTAssertEqual(r.keptShortBouts, 1)
        XCTAssertEqual(r.rejectedTicks, 20)
        XCTAssertEqual(r.rejectedShortBouts, 1)
    }

    func testIncrementsWithinTheGapJoinOneBout() {
        // 25 + 25 seconds of walking split by a 5 s pause: one 100-tick bout, not two short ones.
        let first = walk(from: 1_000, seconds: 25)
        let second = walk(from: 1_029, seconds: 25, counter: 50)
        let r = count(first + second)
        XCTAssertEqual(r.sustainedTicks, 100)
        XCTAssertEqual(r.rejectedShortBouts, 0)
    }

    func testStartReleaseIsCreditedToTheFollowingBout() {
        // The pedometer releases 7 buffered steps in one second while the record still says still (0).
        var samples = [StepSample(ts: 999, counter: 0, activityClass: 0),
                       StepSample(ts: 1_000, counter: 7, activityClass: 0)]
        samples += walk(from: 1_002, seconds: 30, counter: 7).dropFirst()
        let r = count(samples)
        XCTAssertEqual(r.startBurstTicks, 7)
        XCTAssertEqual(r.sustainedTicks, 67)
        XCTAssertEqual(r.legacyTicks, 60, "the current counter rejects the release by its class")
    }

    func testStartReleaseWithoutFollowingWalkIsDropped() {
        var samples = [StepSample(ts: 999, counter: 0, activityClass: 0),
                       StepSample(ts: 1_000, counter: 6, activityClass: 0)]
        samples += walk(from: 1_010, seconds: 40, counter: 6).dropFirst()
        let r = count(samples)
        XCTAssertEqual(r.startBurstTicks, 0)
        XCTAssertEqual(r.totalTicks, 80)
    }

    func testOnlyInWindowIncrementsAreTalliedButOutsideWalkingCountsAsContext() {
        // Sustained walk just before the window, short bout just inside it.
        let long = walk(from: 1_000, seconds: 40)
        let short = walk(from: 1_100, seconds: 10, counter: 80)
        let r = count(long + short, 1_090, 2_000)
        XCTAssertEqual(r.sustainedTicks, 0)
        XCTAssertEqual(r.contextTicks, 20)
        XCTAssertEqual(r.legacyTicks, 20)
    }

    func testUnclassedHistoryFormsBoutsWithoutStartReleases() {
        let r = count(walk(from: 1_000, seconds: 40, cls: nil))
        XCTAssertEqual(r.sustainedTicks, 80)
        XCTAssertEqual(r.startBurstTicks, 0)
    }

    func testEmptyAndSingleSampleInputs() {
        XCTAssertEqual(count([]), .empty)
        XCTAssertEqual(count([StepSample(ts: 5, counter: 1, activityClass: 1)]), .empty)
    }
}
