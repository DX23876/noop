import XCTest
import WhoopStore
@testable import Strand

/// The sparse-coverage caveat's tiering gate (`SleepView.sparseStagingNote`), and its two supporting pure
/// helpers `typicalAsleepMin` and `showsMotionStrip`.
///
/// Grilling-session ground truth: on one wearer's 92-night history, `stagingSparse` was set on 57 of 92
/// computed nights, including nights of 10.5h, 12h and 12.75h — the flag alone says nothing about whether
/// a night actually read short. These tests pin the two-tier gate that keeps the badge for the nights that
/// really do, and steps every other sparse night down to a quiet footnote.
final class SleepSparseStagingNoteTests: XCTestCase {

    // MARK: - sparseStagingNote

    func testNotSparseIsNeverNoted() {
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: false, asleepMin: 60, typicalAsleepMin: 400,
                                                    partialTimelineShown: false), .none)
        // Even a short night with no sparse flag says nothing here — the H9/partial-timeline notes own that.
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: false, asleepMin: 60, typicalAsleepMin: nil,
                                                    partialTimelineShown: false), .none)
    }

    func testSparseAndNormalLengthIsSubtle() {
        // 90% of a 440-min typical — comfortably above the 70% floor.
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: true, asleepMin: 396, typicalAsleepMin: 440,
                                                    partialTimelineShown: false), .subtle)
    }

    func testSparseAndShortIsProminent() {
        // 50% of a 440-min typical — below the 70% floor.
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: true, asleepMin: 220, typicalAsleepMin: 440,
                                                    partialTimelineShown: false), .prominent)
    }

    func testExactlyAtTheFractionBoundaryIsNotYetShort() {
        // asleepMin == fraction * typical is NOT "< ", so it stays subtle at the boundary.
        let typical = 400.0
        let boundary = SleepView.sparseShortFraction * typical
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: true, asleepMin: boundary, typicalAsleepMin: typical,
                                                    partialTimelineShown: false), .subtle)
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: true, asleepMin: boundary - 1, typicalAsleepMin: typical,
                                                    partialTimelineShown: false), .prominent)
    }

    func testNoTypicalFallsBackToAFixedFloor() {
        // Fewer than 5 scored nights: no typical yet, so the fixed floor decides.
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: true, asleepMin: SleepView.sparseShortFloorMin - 1,
                                                    typicalAsleepMin: nil, partialTimelineShown: false), .prominent)
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: true, asleepMin: SleepView.sparseShortFloorMin,
                                                    typicalAsleepMin: nil, partialTimelineShown: false), .subtle)
    }

    func testPartialTimelineAlreadyShownStepsDownToSubtleEvenWhenShort() {
        // The partial-timeline note is the stronger, MEASURED claim (a real hole in the timeline); the
        // sparse caveat must never stack a second warning beside it, even on a night that also reads short.
        XCTAssertEqual(SleepView.sparseStagingNote(sparse: true, asleepMin: 60, typicalAsleepMin: 440,
                                                    partialTimelineShown: true), .subtle)
    }

    // MARK: - typicalAsleepMin

    private func day(_ totalSleepMin: Double?) -> DailyMetric {
        DailyMetric(day: "2026-01-01", totalSleepMin: totalSleepMin, efficiency: nil, deepMin: nil,
                   remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                   recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testTypicalAsleepMinNeedsAtLeastFiveScoredNights() {
        XCTAssertNil(SleepView.typicalAsleepMin([day(400), day(420), day(380), day(nil)]))
        XCTAssertNotNil(SleepView.typicalAsleepMin([day(400), day(420), day(380), day(440), day(410)]))
    }

    func testTypicalAsleepMinIsTheMeanOfTheLast30ScoredDays() {
        let days = [day(300), day(500), day(400), day(400), day(400)]
        XCTAssertEqual(SleepView.typicalAsleepMin(days) ?? -1, 400, accuracy: 0.001)
    }

    func testTypicalAsleepMinIgnoresDaysOlderThanTheTrailing30() {
        // 5 old days with a value that would skew the mean if counted, then exactly 30 days of 400 —
        // only the trailing 30 (all 400) may enter the mean.
        let days = Array(repeating: day(9_999), count: 5) + Array(repeating: day(400), count: 30)
        XCTAssertEqual(SleepView.typicalAsleepMin(days) ?? -1, 400, accuracy: 0.001)
    }

    func testTypicalAsleepMinSkipsZeroAndNilEntriesWhenCountingTheFive() {
        // Zero/nil entries within the window are not scored nights and must not count toward the ≥5 floor:
        // 4 real values plus 2 junk entries stays below the floor.
        let fourReal = [day(0), day(nil), day(400), day(420), day(380), day(440)]
        XCTAssertNil(SleepView.typicalAsleepMin(fourReal), "only 4 real nights, below the floor of 5")
        XCTAssertNotNil(SleepView.typicalAsleepMin(fourReal + [day(410)]), "a 5th real night clears the floor")
    }

    // MARK: - showsMotionStrip

    private func block(stagingSparse: Bool?) -> CachedSleepSession {
        CachedSleepSession(startTs: 0, endTs: 100, efficiency: nil, restingHr: nil, avgHrv: nil,
                           stagesJSON: nil, stagingSparse: stagingSparse)
    }

    func testMotionStripShownWhenEpochsPresent() {
        XCTAssertTrue(SleepView.showsMotionStrip(motionEpochCount: 2, blocks: [block(stagingSparse: nil)]))
    }

    func testMotionStripShownForAComputedNightWithNoMotion() {
        // A NOOP-computed night always has an answer about movement (sparse true or false) even when the
        // motion grid came back empty for it — so it gets the honest empty state, not silence.
        XCTAssertTrue(SleepView.showsMotionStrip(motionEpochCount: 0, blocks: [block(stagingSparse: false)]))
        XCTAssertTrue(SleepView.showsMotionStrip(motionEpochCount: 0, blocks: [block(stagingSparse: true)]))
    }

    func testMotionStripHiddenForAnImportedNightWithNoMotion() {
        // Every block nil `stagingSparse` = never staged by NOOP (imported / pre-migration) = never carried
        // per-epoch motion in the first place. A permanent "no movement detail" line there is noise.
        XCTAssertFalse(SleepView.showsMotionStrip(motionEpochCount: 0, blocks: [block(stagingSparse: nil)]))
    }

    func testMotionStripShownWhenAnyBlockInAMixedGroupWasComputed() {
        XCTAssertTrue(SleepView.showsMotionStrip(motionEpochCount: 0,
                                                 blocks: [block(stagingSparse: nil), block(stagingSparse: false)]))
    }
}
