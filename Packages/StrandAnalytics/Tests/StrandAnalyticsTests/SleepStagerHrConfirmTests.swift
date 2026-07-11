import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins the median-vs-mean sleep-run HR confirmation (`SleepStager.confirmSleepWithHR`).
///
/// A real sleep night carries brief arousal / wake HR spikes. The old gate compared the run's MEAN HR to
/// `baseline * hrSleepBaselineMult`, so those spikes could pull the mean over the bar and reject the run
/// (and, for the usual single main-sleep run, drop the WHOLE night -> "no sleep recorded"). Confirming on
/// the run MEDIAN is spike-robust and, because median <= mean for right-skewed HR, only ever RELAXES the
/// gate. These tests pin both halves of that contract. Apple twin of the Android `SleepStagerHrConfirmTest`.
final class SleepStagerHrConfirmTests: XCTestCase {

    private let start = 1_000_000

    /// A run of `n` HR samples: `spikes` of them at `spikeBpm`, the rest at `baseBpm`, 1 Hz from `start`.
    private func hr(_ n: Int, baseBpm: Int, spikes: Int = 0, spikeBpm: Int = 190) -> [HRSample] {
        (0..<n).map { i in HRSample(ts: start + i, bpm: i < spikes ? spikeBpm : baseBpm) }
    }

    private func period(_ durS: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "sleep", start: start, end: start + durS)
    }

    func testSpikyButAsleepRunSurvivesWhereMeanWouldDropIt() {
        // baseline 50 -> gate bar = 52.5 bpm. 600 s run: 570 s asleep at 48, 30 s of arousal at 190.
        // MEAN = (570*48 + 30*190)/600 = 55.1 bpm (over the bar -> old logic REJECTS the run).
        // MEDIAN = 48 bpm (under the bar -> the run is genuinely asleep and is KEPT).
        let seg = hr(600, baseBpm: 48, spikes: 30, spikeBpm: 190)
        let mean = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        let median = HRVAnalyzer.median(seg.map { Double($0.bpm) })
        let bar = 50.0 * SleepStager.hrSleepBaselineMult
        XCTAssertGreaterThan(mean, bar, "fixture: mean must exceed bar")
        XCTAssertLessThanOrEqual(median, bar, "fixture: median must be at/under bar")

        XCTAssertTrue(
            SleepStager.confirmSleepWithHR(period(600), hr: seg, baseline: 50.0),
            "a spiky but truly-asleep run must be confirmed (median under bar)")
    }

    func testGenuinelyElevatedRunIsStillRejected() {
        // An awake run: HR sits at 60 throughout (median 60 > 52.5 bar) -> must FAIL confirmation.
        let seg = hr(600, baseBpm: 60)
        XCTAssertFalse(
            SleepStager.confirmSleepWithHR(period(600), hr: seg, baseline: 50.0),
            "a run whose median HR is above baseline*mult must be rejected")
    }

    func testRunTheMeanAlreadyAcceptedStillPasses() {
        // No skew: flat 48 bpm (mean == median == 48 <= 52.5). The fix must not regress the accept path.
        let seg = hr(600, baseBpm: 48)
        XCTAssertTrue(
            SleepStager.confirmSleepWithHR(period(600), hr: seg, baseline: 50.0),
            "a flat low-HR run accepted under mean must still pass under median")
    }

    func testTooFewSamplesTrustsGravity() {
        // Below hrRefineMinSamples the HR refinement is skipped entirely -> trust gravity (return true).
        let seg = hr(10, baseBpm: 200)
        XCTAssertTrue(
            SleepStager.confirmSleepWithHR(period(600), hr: seg, baseline: 50.0),
            "fewer than hrRefineMinSamples must bypass the HR gate")
    }

    func testNullBaselineTrustsGravity() {
        let seg = hr(600, baseBpm: 200)
        XCTAssertTrue(
            SleepStager.confirmSleepWithHR(period(600), hr: seg, baseline: nil),
            "a nil baseline must bypass the HR gate")
    }
}
