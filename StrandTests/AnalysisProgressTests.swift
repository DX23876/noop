import XCTest
@testable import Strand

/// Pins the analysis-progress read-out: what it may claim, and — more importantly — what it must refuse
/// to claim.
///
/// The card this drives replaced a bare spinner that looked identical for a pass on day 7 and a pass that
/// stopped returning half an hour earlier, while both buttons that could clear it were disabled on the
/// same flag. So the two halves have different standards of proof, and these tests hold them apart: the
/// freshness line reports an OBSERVED gap and must always be available; the time estimate is an inference
/// and must stay silent until it has something to infer from.
@MainActor
final class AnalysisProgressTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func scanning(completed: Int, total: Int = 21,
                          elapsed: TimeInterval, sinceStep: TimeInterval = 0) -> AnalysisProgress {
        AnalysisProgress(stage: .scanning, completedDays: completed, totalDays: total,
                         startedAt: t0, lastStepAt: t0.addingTimeInterval(elapsed - sinceStep))
    }

    // MARK: - The bar

    func testFractionTracksDaysCompleted() {
        XCTAssertEqual(scanning(completed: 0, elapsed: 0).fraction, 0)
        XCTAssertEqual(scanning(completed: 7, total: 21, elapsed: 100).fraction, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(scanning(completed: 21, total: 21, elapsed: 300).fraction, 1)
    }

    /// The surrounding stages are real work on a deep library. Preparing must read as 0 and finishing as
    /// full: a bar frozen at 20/21 through the persist phase invites exactly the "it's stuck" reading the
    /// whole feature exists to prevent.
    func testSurroundingStagesPinTheBarToTheirEnds() {
        let prep = AnalysisProgress(stage: .preparing, completedDays: 0, totalDays: 21,
                                    startedAt: t0, lastStepAt: t0)
        let fin = AnalysisProgress(stage: .finishing, completedDays: 21, totalDays: 21,
                                   startedAt: t0, lastStepAt: t0)
        XCTAssertEqual(prep.fraction, 0)
        XCTAssertEqual(fin.fraction, 1)
    }

    func testZeroDayWindowCannotDivideByZero() {
        let p = AnalysisProgress(stage: .scanning, completedDays: 0, totalDays: 0,
                                 startedAt: t0, lastStepAt: t0)
        XCTAssertEqual(p.fraction, 0)
        XCTAssertNil(p.estimatedSecondsRemaining(now: t0.addingTimeInterval(60)))
    }

    // MARK: - The estimate stays silent until it can justify itself

    /// THE guard. A pass may open on reused days (fingerprint matched, near-instant) and only then reach
    /// re-scored ones at 10–18 s each. A mean taken over two reused days would promise a finish that
    /// cannot happen, so no estimate is offered at all below the day gate.
    func testNoEstimateBeforeEnoughDaysHaveCompleted() {
        for completed in 0..<AnalysisProgress.minDaysForEstimate {
            let p = scanning(completed: completed, elapsed: 60)
            XCTAssertNil(p.estimatedSecondsRemaining(now: t0.addingTimeInterval(60)),
                         "an estimate from \(completed) day(s) extrapolates from nothing")
        }
    }

    /// The other gate: a pass that has run for two seconds has measured nothing, however many days it
    /// claims to have crossed.
    func testNoEstimateBeforeEnoughTimeHasElapsed() {
        let p = scanning(completed: 5, elapsed: 2)
        XCTAssertNil(p.estimatedSecondsRemaining(now: t0.addingTimeInterval(2)))
    }

    func testEstimateExtrapolatesTheMeanOverCompletedDays() {
        // 7 days in 70 s → 10 s/day, 14 days left → 140 s.
        let p = scanning(completed: 7, total: 21, elapsed: 70)
        let eta = p.estimatedSecondsRemaining(now: t0.addingTimeInterval(70))
        XCTAssertEqual(try XCTUnwrap(eta), 140, accuracy: 0.001)
    }

    /// On the last day there is nothing left to extrapolate to; a "0 s left" that then sits through the
    /// whole persist phase would be a worse statement than none.
    func testNoEstimateOnceEveryDayIsBehindIt() {
        let p = scanning(completed: 21, total: 21, elapsed: 300)
        XCTAssertNil(p.estimatedSecondsRemaining(now: t0.addingTimeInterval(300)))
    }

    /// The stages carry no day rate, so neither may produce a number.
    func testStagesOutsideTheLoopOfferNoEstimate() {
        for stage in [AnalysisProgress.Stage.preparing, .finishing] {
            let p = AnalysisProgress(stage: stage, completedDays: 10, totalDays: 21,
                                     startedAt: t0, lastStepAt: t0)
            XCTAssertNil(p.estimatedSecondsRemaining(now: t0.addingTimeInterval(600)),
                         "\(stage) has no per-day rate to extrapolate from")
        }
    }

    // MARK: - Freshness is observed, so it is always available

    func testFreshnessMeasuresTheGapSinceTheLastStep() {
        let p = scanning(completed: 4, elapsed: 100, sinceStep: 12)
        XCTAssertEqual(p.secondsSinceLastStep(now: t0.addingTimeInterval(100)), 12, accuracy: 0.001)
        XCTAssertFalse(p.looksStalled(now: t0.addingTimeInterval(100)))
    }

    /// A clock that has gone backwards (an NTP correction mid-pass) must not print a negative age.
    func testFreshnessNeverGoesNegative() {
        let p = scanning(completed: 4, elapsed: 100, sinceStep: -30)
        XCTAssertEqual(p.secondsSinceLastStep(now: t0.addingTimeInterval(100)), 0)
    }

    func testStallIsReportedOnlyPastTheThreshold() {
        let below = scanning(completed: 4, elapsed: 500,
                             sinceStep: AnalysisProgress.stallSeconds - 1)
        let at = scanning(completed: 4, elapsed: 500, sinceStep: AnalysisProgress.stallSeconds)
        XCTAssertFalse(below.looksStalled(now: t0.addingTimeInterval(500)),
                       "a slow day must not be called a stall")
        XCTAssertTrue(at.looksStalled(now: t0.addingTimeInterval(500)))
    }

    // MARK: - Copy

    /// Rounded UP, never to nearest: an estimate that habitually finishes early reads as reliable, one
    /// that overruns reads as broken.
    func testCoarseDurationRoundsUp() {
        XCTAssertEqual(AnalysisProgressFormat.coarseDuration(0), "5 s")
        XCTAssertEqual(AnalysisProgressFormat.coarseDuration(1), "5 s")
        XCTAssertEqual(AnalysisProgressFormat.coarseDuration(11), "15 s")
        XCTAssertEqual(AnalysisProgressFormat.coarseDuration(59), "60 s")
        XCTAssertEqual(AnalysisProgressFormat.coarseDuration(61), "2 min")
        XCTAssertEqual(AnalysisProgressFormat.coarseDuration(600), "10 min")
    }

    /// The day POSITION is 1-based — a pass that has finished 6 days is working on the 7th, and a card
    /// reading "day 6 of 21" while day 7 is being scored is off by one for its whole run.
    func testDetailLineNamesTheDayBeingWorkedOn() {
        let p = scanning(completed: 6, total: 21, elapsed: 60)
        let line = AnalysisProgressFormat.detailLine(p, now: t0.addingTimeInterval(60))
        XCTAssertTrue(line.contains("7"), line)
        XCTAssertTrue(line.contains("21"), line)
    }

    /// While the estimate is withheld the line must SAY so rather than quietly dropping to just a day
    /// count — a missing estimate that looks like a design choice teaches nothing.
    func testDetailLineAdmitsWhenItCannotEstimateYet() {
        let p = scanning(completed: 1, elapsed: 60)
        let line = AnalysisProgressFormat.detailLine(p, now: t0.addingTimeInterval(60))
        XCTAssertTrue(line.lowercased().contains("estimating"), line)
    }

    /// The stall wording names the GAP; it must not assert a hang, because this line cannot tell a hung
    /// pass from one inside an unusually slow day.
    func testStallCopyReportsTheGapWithoutDiagnosingIt() {
        let p = scanning(completed: 4, elapsed: 600, sinceStep: 300)
        let line = AnalysisProgressFormat.freshnessLine(p, now: t0.addingTimeInterval(600))
        XCTAssertTrue(line.contains("5 min"), line)
        XCTAssertFalse(line.lowercased().contains("hung"), line)
        XCTAssertFalse(line.lowercased().contains("stuck"), line)
    }
}

/// Pins the reuse read-out (#1005 follow-up).
///
/// Reported the morning after day-reuse shipped: "instead of analysing a single day it does a 21-day
/// analysis again". It was not — the completed pass took 49 s where the un-reusing one took 2261 s. What
/// the wearer saw was THIS card: the loop walks the whole window even when nearly every day is a
/// fingerprint match, so the counter still races 1 → 21 and a bare "Day 7 of 21" reads exactly like the
/// full re-derivation that had just been fixed. The number was true and the impression it left was wrong.
@MainActor
final class AnalysisProgressReuseTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func scanning(completed: Int, reused: Int, total: Int = 21) -> AnalysisProgress {
        AnalysisProgress(stage: .scanning, completedDays: completed, reusedDays: reused,
                         totalDays: total, startedAt: t0, lastStepAt: t0.addingTimeInterval(60))
    }

    /// THE fix: when days are being reused, the line has to say so — that is the answer to the question
    /// the counter provokes.
    func testScanningLineReportsReusedDays() {
        let line = AnalysisProgressFormat.detailLine(scanning(completed: 7, reused: 5),
                                                     now: t0.addingTimeInterval(60))
        // 7 days behind it means it is working on the 8th — the position is 1-based (see
        // `testDetailLineNamesTheDayBeingWorkedOn`).
        XCTAssertTrue(line.contains("8"), line)
        XCTAssertTrue(line.contains("21"), line)
        XCTAssertTrue(line.contains("5"), "the reuse count is the point of this line: \(line)")
    }

    /// A pass that is genuinely re-deriving everything says nothing about reuse — there is none, and an
    /// "0 unchanged" would be noise on the one pass where the full count is real work.
    func testNoReuseAddsNoClause() {
        let line = AnalysisProgressFormat.detailLine(scanning(completed: 7, reused: 0),
                                                     now: t0.addingTimeInterval(60))
        XCTAssertFalse(line.lowercased().contains("unchanged"), line)
    }

    /// The finishing line states the SPLIT, because that is what a wearer reads when they finally look:
    /// "re-derived 2 of 21" is the whole difference between a working pass and the runaway one.
    func testFinishingLineStatesTheSplit() {
        let p = AnalysisProgress(stage: .finishing, completedDays: 21, reusedDays: 19,
                                 totalDays: 21, startedAt: t0, lastStepAt: t0)
        let line = AnalysisProgressFormat.detailLine(p, now: t0)
        XCTAssertTrue(line.contains("2"), "21 total minus 19 reused is 2 re-derived: \(line)")
        XCTAssertTrue(line.contains("21"), line)
    }

    /// With nothing reused the finishing line stays the plain one — no invented split.
    func testFinishingWithoutReuseStaysPlain() {
        let p = AnalysisProgress(stage: .finishing, completedDays: 21, reusedDays: 0,
                                 totalDays: 21, startedAt: t0, lastStepAt: t0)
        XCTAssertFalse(AnalysisProgressFormat.detailLine(p, now: t0).contains("re-derived"))
    }

    /// Reuse must not disturb the bar or the freshness half — those answer different questions and are
    /// pinned separately.
    func testReuseDoesNotChangeFractionOrFreshness() {
        let a = scanning(completed: 7, reused: 0)
        let b = scanning(completed: 7, reused: 5)
        XCTAssertEqual(a.fraction, b.fraction)
        XCTAssertEqual(a.secondsSinceLastStep(now: t0.addingTimeInterval(60)),
                       b.secondsSinceLastStep(now: t0.addingTimeInterval(60)))
    }
}
