import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #737: the per-pair sparse-bridge diagnostic must describe what `bridgeSparseSleep` ACTUALLY did, so a
/// "runsBefore == runsAfter" night finally says why. Every test pins the diagnostic against the real
/// bridge rather than asserting it in isolation.
final class SparseBridgeAttemptTests: XCTestCase {

    /// Sleep HR well under any plausible baseline, so `hrSleepBandAcross` is satisfied when we want it.
    private func sleepHR(from: Int, to: Int, bpm: Int = 50) -> [HRSample] {
        stride(from: from, through: to, by: 30).map { HRSample(ts: $0, bpm: bpm) }
    }

    private func sleep(_ start: Int, _ end: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "sleep", start: start, end: end)
    }
    private func active(_ start: Int, _ end: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "active", start: start, end: end)
    }

    /// The invariant that makes the diagnostic trustworthy: the number of pairs it reports as bridged
    /// must equal the reduction in sleep-run count the REAL bridge produces.
    private func assertAgreesWithBridge(_ periods: [SleepStager.Period], hr: [HRSample],
                                        baseline: Double?, file: StaticString = #filePath, line: UInt = #line) {
        let attempts = SleepStager.sparseBridgeAttempts(periods, sparse: true, hr: hr, baseline: baseline)
        let before = periods.filter { $0.stage == "sleep" }.count
        let after = SleepStager.bridgeSparseSleep(periods, sparse: true, hr: hr, baseline: baseline)
            .filter { $0.stage == "sleep" }.count
        XCTAssertEqual(attempts.filter { $0.bridged }.count, before - after,
                       "bridged-pair count must equal the real bridge's run reduction", file: file, line: line)
    }

    func testShortGapInSleepBandBridgesAndIsReported() {
        // Two sleep runs 10 min apart, HR asleep across the gap → bridged.
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000)]
        let hr = sleepHR(from: 0, to: 8_000)
        let a = SleepStager.sparseBridgeAttempts(periods, sparse: true, hr: hr, baseline: 70)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].gapMin, 10)
        XCTAssertTrue(a[0].bridged)
        XCTAssertEqual(a[0].reason, "bridged")
        assertAgreesWithBridge(periods, hr: hr, baseline: 70)
    }

    func testGapBeyondToleranceReportsGapTooLong() {
        // 120 min apart — over sparseBridgeGapMin (90), so the bridge declines and says so.
        let gap = (SleepStager.sparseBridgeGapMin + 30) * 60
        let periods = [sleep(0, 3_600), sleep(3_600 + gap, 3_600 + gap + 3_600)]
        let hr = sleepHR(from: 0, to: 3_600 + gap + 3_600)
        let a = SleepStager.sparseBridgeAttempts(periods, sparse: true, hr: hr, baseline: 70)
        XCTAssertEqual(a.count, 1)
        XCTAssertFalse(a[0].bridged)
        XCTAssertEqual(a[0].reason, "gapTooLong")
        XCTAssertEqual(a[0].gapMin, SleepStager.sparseBridgeGapMin + 30)
        assertAgreesWithBridge(periods, hr: hr, baseline: 70)
    }

    func testAwakeHrAcrossGapReportsHrOutOfBand() {
        // Gap is short enough, but HR across it is clearly awake → the HR condition is what refused.
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000)]
        let hr = sleepHR(from: 0, to: 8_000, bpm: 110)
        let a = SleepStager.sparseBridgeAttempts(periods, sparse: true, hr: hr, baseline: 60)
        XCTAssertEqual(a.count, 1)
        XCTAssertFalse(a[0].bridged)
        XCTAssertFalse(a[0].hrInSleepBand)
        XCTAssertEqual(a[0].reason, "hrOutOfBand")
        assertAgreesWithBridge(periods, hr: hr, baseline: 60)
    }

    /// The reporter's shape (#737): fragments separated by ACTIVE runs are never adjacent sleep pairs, so
    /// the bridge considers nothing — which is exactly why their log showed runsBefore == runsAfter with
    /// no explanation. An EMPTY attempt list is the diagnosis, and the emitter says so in words.
    func testFragmentsSeparatedByActiveRunsProduceNoAttempts() {
        let periods = [sleep(0, 3_000), active(3_000, 3_300), sleep(3_300, 6_000)]
        let hr = sleepHR(from: 0, to: 6_000)
        let a = SleepStager.sparseBridgeAttempts(periods, sparse: true, hr: hr, baseline: 70)
        XCTAssertTrue(a.isEmpty, "an intervening active run is never a considered pair")
        assertAgreesWithBridge(periods, hr: hr, baseline: 70)   // and the real bridge merges nothing
    }

    func testNoOpWhenNotSparse() {
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000)]
        let hr = sleepHR(from: 0, to: 8_000)
        XCTAssertTrue(SleepStager.sparseBridgeAttempts(periods, sparse: false, hr: hr, baseline: 70).isEmpty,
                      "the dense 4.0 path is untouched, so there is nothing to explain")
    }

    /// A chain of three bridgeable runs must report two pairs and agree with the real bridge's collapse
    /// to one run — the case where a naive diagnostic (not re-walking the growing run) would drift.
    func testChainOfThreeReportsTwoPairsAndAgrees() {
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000), sleep(8_600, 12_000)]
        let hr = sleepHR(from: 0, to: 12_000)
        let a = SleepStager.sparseBridgeAttempts(periods, sparse: true, hr: hr, baseline: 70)
        XCTAssertEqual(a.count, 2)
        XCTAssertTrue(a.allSatisfy { $0.bridged })
        assertAgreesWithBridge(periods, hr: hr, baseline: 70)
    }
}
