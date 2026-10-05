import XCTest
@testable import StrandAnalytics

final class LongTermGoalMathTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 00:00 UTC
    private func at(_ days: Double) -> Date { t0.addingTimeInterval(days * day) }
    private func samples(_ values: [Double], endingAt end: Double) -> [GoalMilestones.Sample] {
        values.enumerated().map { GoalMilestones.Sample(date: at(end - Double(values.count - 1 - $0.offset)), value: $0.element) }
    }

    // MARK: - Sum

    /// 1,000 km over a year, half the year gone, half collected: on track, with the rest spread evenly.
    func testSumAtEvenPaceIsOnTrack() throws {
        let r = try XCTUnwrap(LongTermGoalMath.sum(total: 500, target: 1_000, start: t0, end: at(364), now: at(182),
                                                    recentWeeklyTotals: [20, 20, 20, 20], capFraction: 0.1))
        XCTAssertEqual(r.state, .onTrack)
        XCTAssertEqual(r.plannedByNow, 500, accuracy: 1e-9)
        XCTAssertEqual(r.weeksLeft, 26)
        XCTAssertEqual(r.neededPerWeek ?? 0, 500 / 26, accuracy: 1e-9)
        XCTAssertEqual(r.recentWeeklyAverage, 20)
        XCTAssertEqual(r.fraction, 0.5, accuracy: 1e-9)
        let finish = try XCTUnwrap(r.projectedFinish)
        XCTAssertEqual(finish.timeIntervalSince(at(182)) / day, 175, accuracy: 1e-6, "500 km at 20 a week")
    }

    func testSumLeadingThePlanIsAhead() throws {
        let r = try XCTUnwrap(LongTermGoalMath.sum(total: 600, target: 1_000, start: t0, end: at(364), now: at(182),
                                                    recentWeeklyTotals: [], capFraction: 0.1))
        XCTAssertEqual(r.state, .ahead)
    }

    /// A small shortfall with a slow recent pace is close; a larger one is behind.
    func testSumShortfallReadsCloseThenBehind() throws {
        let slow: [Double] = [10, 10, 10, 10]
        let close = try XCTUnwrap(LongTermGoalMath.sum(total: 460, target: 1_000, start: t0, end: at(364), now: at(182),
                                                        recentWeeklyTotals: slow, capFraction: 0.1))
        XCTAssertEqual(close.state, .close)
        let behind = try XCTUnwrap(LongTermGoalMath.sum(total: 400, target: 1_000, start: t0, end: at(364), now: at(182),
                                                         recentWeeklyTotals: slow, capFraction: 0.1))
        XCTAssertEqual(behind.state, .behind)
    }

    /// Behind the even line, but the recent weeks would finish in time: that is on track.
    func testSumCatchingUpIsOnTrack() throws {
        let r = try XCTUnwrap(LongTermGoalMath.sum(total: 400, target: 1_000, start: t0, end: at(364), now: at(182),
                                                    recentWeeklyTotals: [30, 30, 30, 30], capFraction: 0.1))
        XCTAssertEqual(r.state, .onTrack)
    }

    /// The weekly suggestion never asks for more than the cap above the recent average, and says so.
    func testSumSuggestionIsCappedAboveRecentAverage() throws {
        let r = try XCTUnwrap(LongTermGoalMath.sum(total: 400, target: 1_000, start: t0, end: at(364), now: at(182),
                                                    recentWeeklyTotals: [15, 15, 15, 15], capFraction: 0.1))
        XCTAssertEqual(r.neededPerWeek ?? 0, 600 / 26, accuracy: 1e-9)
        XCTAssertEqual(r.suggestedWeeklyTarget ?? 0, 16.5, accuracy: 1e-9)
        XCTAssertTrue(r.catchUpExceedsCap)
    }

    /// Fewer than four weeks of history: no recent pace, no projection, no cap.
    func testSumWithoutPaceHistoryProjectsNothing() throws {
        let r = try XCTUnwrap(LongTermGoalMath.sum(total: 400, target: 1_000, start: t0, end: at(364), now: at(182),
                                                    recentWeeklyTotals: [30, 30], capFraction: 0.1))
        XCTAssertNil(r.recentWeeklyAverage)
        XCTAssertNil(r.projectedFinish)
        XCTAssertEqual(r.suggestedWeeklyTarget, r.neededPerWeek)
        XCTAssertFalse(r.catchUpExceedsCap)
    }

    func testSumReachedEndedAndStarting() throws {
        let reached = try XCTUnwrap(LongTermGoalMath.sum(total: 1_020, target: 1_000, start: t0, end: at(364),
                                                          now: at(300), recentWeeklyTotals: [], capFraction: 0.1))
        XCTAssertEqual(reached.state, .achieved)
        XCTAssertNil(reached.neededPerWeek)
        XCTAssertEqual(reached.remaining, 0)

        let ended = try XCTUnwrap(LongTermGoalMath.sum(total: 900, target: 1_000, start: t0, end: at(364),
                                                        now: at(370), recentWeeklyTotals: [], capFraction: 0.1))
        XCTAssertEqual(ended.state, .outOfReach)
        XCTAssertEqual(ended.weeksLeft, 0)
        XCTAssertNil(ended.neededPerWeek)

        let starting = try XCTUnwrap(LongTermGoalMath.sum(total: 5, target: 1_000, start: t0, end: at(364),
                                                           now: at(3), recentWeeklyTotals: [], capFraction: 0.1))
        XCTAssertEqual(starting.state, .starting)
    }

    /// A finish more than a year away is not projected.
    func testSumProjectionStopsAtAYear() throws {
        let r = try XCTUnwrap(LongTermGoalMath.sum(total: 100, target: 1_000, start: t0, end: at(728), now: at(60),
                                                    recentWeeklyTotals: [5, 5, 5, 5], capFraction: 0.1))
        XCTAssertNil(r.projectedFinish, "900 km at 5 a week is three and a half years")
    }

    func testSumRejectsNonsense() {
        XCTAssertNil(LongTermGoalMath.sum(total: 1, target: 0, start: t0, end: at(10), now: at(1),
                                          recentWeeklyTotals: [], capFraction: 0.1))
        XCTAssertNil(LongTermGoalMath.sum(total: 1, target: 10, start: at(10), end: t0, now: at(1),
                                          recentWeeklyTotals: [], capFraction: 0.1))
    }

    // MARK: - Target value without a date

    /// 217 → 100 kg: ten-kilo waypoints, and the band shows the first five while only one is passed.
    func testUndatedWeightRouteUsesFineStepsAndShowsFive() throws {
        let w = try XCTUnwrap(LongTermGoalMath.milestoneWindow(baseline: 217, target: 100, current: 203.8))
        XCTAssertEqual(w.values, [210, 200, 190, 180, 170, 160, 150, 140, 130, 120, 110, 100])
        XCTAssertEqual(w.reachedCount, 1)
        XCTAssertEqual(w.next, 200)
        XCTAssertEqual(w.visible, 0..<5)
    }

    /// Mid-way the band shows two passed waypoints, the next one and two to come.
    func testMilestoneWindowCentresOnTheNextWaypoint() throws {
        let w = try XCTUnwrap(LongTermGoalMath.milestoneWindow(baseline: 217, target: 100, current: 150))
        XCTAssertEqual(w.reachedCount, 7)
        XCTAssertEqual(w.next, 140)
        XCTAssertEqual(Array(w.values[w.visible]), [160, 150, 140, 130, 120])
    }

    func testMilestoneWindowAtTheEndShowsTheLastFive() throws {
        let w = try XCTUnwrap(LongTermGoalMath.milestoneWindow(baseline: 217, target: 100, current: 99))
        XCTAssertEqual(w.reachedCount, 12)
        XCTAssertNil(w.next)
        XCTAssertEqual(w.visible, 7..<12)
    }

    func testAscendingRouteCountsUpInRoundSteps() throws {
        let w = try XCTUnwrap(LongTermGoalMath.milestoneWindow(baseline: 0, target: 1_000, current: 642))
        XCTAssertEqual(w.values, [100, 200, 300, 400, 500, 600, 700, 800, 900, 1_000])
        XCTAssertEqual(w.next, 700)
        XCTAssertEqual(Array(w.values[w.visible]), [500, 600, 700, 800, 900])
    }

    /// A short goal keeps half-kilo steps instead of quarter steps.
    func testShortRouteKeepsTheDatedSteps() throws {
        let w = try XCTUnwrap(LongTermGoalMath.milestoneWindow(baseline: 82, target: 79, current: 81.5))
        XCTAssertEqual(w.values, [81.5, 81, 80.5, 80, 79.5, 79])
        XCTAssertEqual(w.values, GoalMilestones.values(baseline: 82, target: 79))
        XCTAssertEqual(w.reachedCount, 1)
        XCTAssertEqual(w.visible, 0..<5)
    }

    func testValuesMatchTheDatedRoute() {
        let values = GoalMilestones.values(baseline: 100, target: 70)
        let dated = GoalMilestones.suggest(baseline: 100, target: 70, createdAt: t0, targetDate: at(180))
        XCTAssertEqual(values, dated.map(\.value))
    }

    /// The next mark gets a date from the trend; the far target does not, and a trend pointing away
    /// gives no date at all.
    func testProjectedDatesStayWithinAYearAndTheRightDirection() throws {
        let rate = -0.6 / 7
        let next = try XCTUnwrap(LongTermGoalMath.projectedDate(current: 203.8, mark: 200, ratePerDay: rate, now: t0))
        XCTAssertEqual(next.timeIntervalSince(t0) / day, 3.8 / 0.6 * 7, accuracy: 1e-6)
        XCTAssertNil(LongTermGoalMath.projectedDate(current: 203.8, mark: 100, ratePerDay: rate, now: t0))
        XCTAssertNil(LongTermGoalMath.projectedDate(current: 203.8, mark: 200, ratePerDay: 0.1, now: t0))
        XCTAssertNil(LongTermGoalMath.projectedDate(current: 203.8, mark: 200, ratePerDay: nil, now: t0))
    }

    func testUndatedStateFollowsTheTrendDirection() {
        XCTAssertEqual(LongTermGoalMath.undatedState(baseline: 217, target: 100, current: 203, ratePerDay: -0.1), .onTrack)
        XCTAssertEqual(LongTermGoalMath.undatedState(baseline: 217, target: 100, current: 203, ratePerDay: 0.1), .behind)
        XCTAssertNil(LongTermGoalMath.undatedState(baseline: 217, target: 100, current: 203, ratePerDay: nil))
        XCTAssertEqual(LongTermGoalMath.undatedState(baseline: 217, target: 100, current: 99, ratePerDay: nil), .achieved)
        XCTAssertEqual(LongTermGoalMath.undatedState(baseline: 40, target: 45, current: 41, ratePerDay: 0.01), .onTrack)
    }

    // MARK: - Maintain

    func testMaintainJudgesTheShareInsideTheBand() {
        let onTrack = LongTermGoalMath.maintain(samples: samples([80.2, 80.8, 79.5, 81.4, 80.1, 80.0], endingAt: 27),
                                                center: 80, band: 1, now: at(27))
        XCTAssertEqual(onTrack.inBandShare ?? 0, 5.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(onTrack.state, .onTrack)
        XCTAssertEqual(onTrack.deviation ?? 99, 0, accuracy: 1e-9)
        XCTAssertEqual(onTrack.spread ?? 0, 1.9, accuracy: 1e-9)

        let close = LongTermGoalMath.maintain(samples: samples([80, 80.5, 81.5, 82, 80.3], endingAt: 27),
                                              center: 80, band: 1, now: at(27))
        XCTAssertEqual(close.state, .close)

        let starting = LongTermGoalMath.maintain(samples: samples([80, 80.5, 81], endingAt: 27),
                                                 center: 80, band: 1, now: at(27))
        XCTAssertEqual(starting.state, .starting)

        let none = LongTermGoalMath.maintain(samples: [], center: 80, band: 1, now: at(27))
        XCTAssertEqual(none.state, .noData)
        XCTAssertNil(none.inBandShare)
    }

    // MARK: - Best value

    /// Only efforts since the goal started count; an older best is context, not the score.
    func testBestCountsOnlySinceTheStart() {
        let s = [GoalMilestones.Sample(date: at(-100), value: 12),
                 GoalMilestones.Sample(date: at(10), value: 8),
                 GoalMilestones.Sample(date: at(25), value: 9.5)]
        let r = LongTermGoalMath.best(samples: s, since: t0, target: 10, now: at(30))
        XCTAssertEqual(r.best, 9.5)
        XCTAssertEqual(r.bestDate, at(25))
        XCTAssertEqual(r.daysSinceBest, 5)
        XCTAssertEqual(r.earlierBest, 12)
        XCTAssertEqual(r.recentBest, 9.5)
        XCTAssertEqual(r.fraction ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertNil(r.state, "without a date a best effort is not late")
    }

    /// The recent window is the last four weeks, not the part of them since the start: a goal set
    /// today shows the run from last week, and stays "starting" until an effort inside the goal.
    func testRecentBestReadsTheWholeWindow() {
        let s = [GoalMilestones.Sample(date: at(-60), value: 12),
                 GoalMilestones.Sample(date: at(-10), value: 7.1),
                 GoalMilestones.Sample(date: at(-3), value: 6)]
        let plan = LongTermGoalMath.BestPlan(baseline: 7.1, start: t0, end: at(84))
        let r = LongTermGoalMath.best(samples: s, since: t0, target: 10, plan: plan, now: at(0))
        XCTAssertNil(r.best)
        XCTAssertEqual(r.recentBest, 7.1)
        XCTAssertEqual(r.earlierBest, 12)
        XCTAssertEqual(r.state, .starting)
    }

    /// Weight marks are half a kilo up to 10 kg and a kilo beyond, however long the route: the band
    /// shows the next five and moves along with the wearer.
    func testWeightMilestonesUseSmallFixedSteps() {
        XCTAssertEqual(LongTermGoalMath.weightMilestoneStep(baseline: 96, target: 91), 0.5)
        XCTAssertEqual(LongTermGoalMath.weightMilestoneStep(baseline: 96, target: 56), 1)
        XCTAssertEqual(LongTermGoalMath.weightMilestoneStep(baseline: 70, target: 90), 1)
        let big = LongTermGoalMath.milestoneWindow(baseline: 96, target: 56, current: 80, step: 1)!
        XCTAssertEqual(big.values.count, 40)
        XCTAssertEqual(big.values.first, 95)
        XCTAssertEqual(big.values.last, 56)
        XCTAssertEqual(big.reachedCount, 16)
        XCTAssertEqual(big.next, 79)
        XCTAssertEqual(big.visible.map { big.values[$0] }, [81, 80, 79, 78, 77])
        let gain = LongTermGoalMath.milestoneWindow(baseline: 70, target: 72.3, current: 70.6, step: 0.5)!
        XCTAssertEqual(gain.values, [70.5, 71, 71.5, 72, 72.3])
        XCTAssertEqual(gain.reachedCount, 1)
    }

    func testBestReachingTheTargetIsAchieved() {
        let s = [GoalMilestones.Sample(date: at(20), value: 10.2)]
        XCTAssertEqual(LongTermGoalMath.best(samples: s, since: t0, target: 10, now: at(30)).state, .achieved)
    }

    /// With a date, the recent best is held against the planned line.
    func testDatedBestFollowsThePlannedRoute() {
        let plan = LongTermGoalMath.BestPlan(baseline: 5, start: t0, end: at(70))
        let keeping = [GoalMilestones.Sample(date: at(30), value: 8)]
        XCTAssertEqual(LongTermGoalMath.best(samples: keeping, since: t0, target: 10, plan: plan, now: at(35)).state,
                       .onTrack, "7.5 planned by now")
        let slipping = [GoalMilestones.Sample(date: at(30), value: 7)]
        XCTAssertEqual(LongTermGoalMath.best(samples: slipping, since: t0, target: 10, plan: plan, now: at(35)).state,
                       .behind)
        XCTAssertEqual(LongTermGoalMath.best(samples: [], since: t0, target: 10, plan: plan, now: at(35)).state,
                       .starting)
    }

    func testLowerIsBetterBest() {
        let s = [GoalMilestones.Sample(date: at(5), value: 1_620), GoalMilestones.Sample(date: at(9), value: 1_560)]
        let r = LongTermGoalMath.best(samples: s, since: t0, target: 1_500, higherIsBetter: false, now: at(10))
        XCTAssertEqual(r.best, 1_560)
        XCTAssertEqual(r.fraction ?? 0, 1_500.0 / 1_560.0, accuracy: 1e-9)
    }

    // MARK: - Consistency

    /// Protected weeks do not count, an almost week counts as evaluated but not hit, and the series
    /// follows the weekly goals' own rule.
    func testAdherenceCountsOnlyEvaluatedWeeks() {
        let weeks: [PeriodOutcome] = [.missed] + Array(repeating: .achieved, count: 9) + [.protected, .almost]
        let r = LongTermGoalMath.adherence(weeks: weeks)
        XCTAssertEqual(r.hit, 9)
        XCTAssertEqual(r.evaluated, 11)
        XCTAssertEqual(r.share ?? 0, 9.0 / 11.0, accuracy: 1e-9)
        XCTAssertEqual(r.state, .onTrack)
        XCTAssertEqual(r.currentStreak, 10)
        XCTAssertEqual(r.bestStreak, 10)
    }

    func testAdherenceStatesByShare() {
        XCTAssertEqual(LongTermGoalMath.adherence(weeks: [.achieved, .achieved, .missed]).state, .starting)
        let close: [PeriodOutcome] = [.achieved, .achieved, .achieved, .missed, .achieved, .achieved, .missed,
                                      .achieved, .achieved, .missed]
        XCTAssertEqual(LongTermGoalMath.adherence(weeks: close).state, .close)
        let behind: [PeriodOutcome] = [.achieved, .missed, .achieved, .missed, .missed, .achieved]
        XCTAssertEqual(LongTermGoalMath.adherence(weeks: behind).state, .behind)
    }

    /// An open goal looks at the last twelve weeks; old misses fall out of the window.
    func testAdherenceWindowDropsOldWeeks() {
        let weeks: [PeriodOutcome] = Array(repeating: .missed, count: 5) + Array(repeating: .achieved, count: 12)
        XCTAssertEqual(LongTermGoalMath.adherence(weeks: weeks).share, 1)
        XCTAssertEqual(LongTermGoalMath.adherence(weeks: weeks, window: weeks.count).share ?? 0, 12.0 / 17.0,
                       accuracy: 1e-9)
    }

    func testStrongestWeekday() throws {
        let days = ["2026-10-06", "2026-10-13", "2026-10-20", "2026-10-05", "2026-10-09"]
        let best = try XCTUnwrap(LongTermGoalMath.strongestWeekday(eventDays: days))
        XCTAssertEqual(best.weekday, 3, "Tuesday")
        XCTAssertEqual(best.share, 0.6, accuracy: 1e-9)
        XCTAssertNil(LongTermGoalMath.strongestWeekday(eventDays: ["2026-10-06", "2026-10-13", "2026-10-05", "2026-10-12"]),
                     "a tie names no day")
        XCTAssertNil(LongTermGoalMath.strongestWeekday(eventDays: ["2026-10-06", "2026-10-13"]))
    }

    // MARK: - Average

    /// Eight weeks of nights rising toward 7.5 h: below the target, moving toward it.
    func testAverageRisingTowardTheTargetIsOnTrack() throws {
        let values = (0..<56).map { 6.5 + Double($0) * 0.9 / 55 }
        let r = LongTermGoalMath.average(samples: samples(values, endingAt: 100), target: 7.5, now: at(100))
        let mean = try XCTUnwrap(r.mean)
        XCTAssertEqual(mean, values.suffix(28).reduce(0, +) / 28, accuracy: 1e-9)
        XCTAssertEqual(r.values, 28)
        XCTAssertEqual(r.state, .onTrack)
        XCTAssertEqual(r.trendPerMonth ?? 0, 0.9 / 55 * 30.44, accuracy: 1e-6)
        XCTAssertEqual(r.gap ?? 0, 7.5 - mean, accuracy: 1e-9)
    }

    func testAverageFallingIsBehind() {
        let values = (0..<56).map { 7.4 - Double($0) * 0.8 / 55 }
        XCTAssertEqual(LongTermGoalMath.average(samples: samples(values, endingAt: 100), target: 7.5, now: at(100)).state,
                       .behind)
    }

    func testFlatAverageIsCloseOnlyNearTheTarget() {
        let near = LongTermGoalMath.average(samples: samples(Array(repeating: 7.4, count: 56), endingAt: 100),
                                            target: 7.5, now: at(100))
        XCTAssertEqual(near.state, .close)
        let far = LongTermGoalMath.average(samples: samples(Array(repeating: 6.0, count: 56), endingAt: 100),
                                           target: 7.5, now: at(100))
        XCTAssertEqual(far.state, .behind)
    }

    func testAverageAtTargetIsAchievedAndCountsDays() {
        let values = Array(repeating: 7.0, count: 10) + Array(repeating: 8.0, count: 18)
        let r = LongTermGoalMath.average(samples: samples(values, endingAt: 100), target: 7.5, now: at(100))
        XCTAssertEqual(r.atTarget, 18)
        XCTAssertEqual(r.state, .achieved)
        XCTAssertEqual(r.gap, 0)
    }

    func testAverageNeedsEnoughValues() {
        let few = LongTermGoalMath.average(samples: samples(Array(repeating: 7, count: 10), endingAt: 100),
                                           target: 7.5, now: at(100))
        XCTAssertNil(few.mean)
        XCTAssertEqual(few.state, .noData)
        let noTrend = LongTermGoalMath.average(samples: samples(Array(repeating: 7, count: 20), endingAt: 100),
                                               target: 7.5, now: at(100))
        XCTAssertNotNil(noTrend.mean)
        XCTAssertNil(noTrend.trendPerMonth)
        XCTAssertEqual(noTrend.state, .starting)
    }

    /// Resting heart rate: lower is better, so a falling line is the good direction.
    func testLowerIsBetterAverage() {
        let falling = (0..<56).map { 60 - Double($0) * 3 / 55 }
        XCTAssertEqual(LongTermGoalMath.average(samples: samples(falling, endingAt: 100), target: 55,
                                                higherIsBetter: false, now: at(100)).state, .onTrack)
        let low = LongTermGoalMath.average(samples: samples(Array(repeating: 54, count: 30), endingAt: 100),
                                           target: 55, higherIsBetter: false, now: at(100))
        XCTAssertEqual(low.state, .achieved)
    }

    // MARK: - Running pace

    func testPaceIsTotalTimeOverTotalDistance() throws {
        let runs = [LongTermGoalMath.RunSample(date: at(90), distanceM: 5_000, durationS: 1_500),
                    LongTermGoalMath.RunSample(date: at(95), distanceM: 10_000, durationS: 3_300),
                    LongTermGoalMath.RunSample(date: at(96), distanceM: 2_000, durationS: 500),
                    LongTermGoalMath.RunSample(date: at(50), distanceM: 8_000, durationS: 2_000)]
        let pace = try XCTUnwrap(LongTermGoalMath.pace(runs: runs, now: at(100)))
        XCTAssertEqual(pace.secondsPerKm, 320, accuracy: 1e-9)
        XCTAssertEqual(pace.runs, 2)
        XCTAssertNil(LongTermGoalMath.pace(runs: [runs[2]], now: at(100)))
    }

    /// "Run faster": the weighted pace of the window, judged lower-is-better, with a trend only from
    /// four runs on.
    func testPaceAverageImprovingTowardTarget() throws {
        // Six 5 km runs over eight weeks, each 10 s/km quicker than the last: 330 down to 280 s/km.
        let runs = (0..<6).map { i in
            LongTermGoalMath.RunSample(date: at(44 + Double(i) * 11), distanceM: 5_000,
                                       durationS: 5 * (330 - Double(i) * 10))
        }
        let reading = LongTermGoalMath.paceAverage(runs: runs, targetSecondsPerKm: 270, now: at(100))
        // Inside 28 days: the runs on days 77, 88 and 99 (300, 290 and 280 s/km), equal distance.
        XCTAssertEqual(try XCTUnwrap(reading.mean), 290, accuracy: 1e-9)
        XCTAssertEqual(reading.values, 3)
        XCTAssertEqual(reading.atTarget, 0)
        XCTAssertEqual(try XCTUnwrap(reading.gap), 20, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(reading.trendPerMonth), 0)
        XCTAssertEqual(reading.state, .onTrack)

        let reached = LongTermGoalMath.paceAverage(runs: runs, targetSecondsPerKm: 290, now: at(100))
        XCTAssertEqual(reached.state, .achieved)
        XCTAssertEqual(reached.atTarget, 2)
    }

    func testPaceAverageNeedsTwoRunsAndIgnoresShortOnes() {
        let one = [LongTermGoalMath.RunSample(date: at(95), distanceM: 5_000, durationS: 1_500)]
        let reading = LongTermGoalMath.paceAverage(runs: one, targetSecondsPerKm: 280, now: at(100))
        XCTAssertNil(reading.mean)
        XCTAssertEqual(reading.state, .starting, "one run is a start, the mean waits for the second")
        XCTAssertEqual(LongTermGoalMath.paceAverage(runs: [], targetSecondsPerKm: 280, now: at(100)).state, .noData)
        let short = one + [LongTermGoalMath.RunSample(date: at(96), distanceM: 2_000, durationS: 500)]
        XCTAssertNil(LongTermGoalMath.paceAverage(runs: short, targetSecondsPerKm: 280, now: at(100)).mean)
    }

    // MARK: - Level of a sparse series

    func testLevelIsTheWindowMeanAndProvisionalBelowTheMinimum() throws {
        let readings = samples([20, 21, 22, 23], endingAt: 100)
        let level = try XCTUnwrap(LongTermGoalMath.level(samples: readings, now: at(100), windowDays: 3, minValues: 3))
        // Days 98, 99, 100 fall inside a three-day window ending today.
        XCTAssertEqual(level.value, 22, accuracy: 1e-9)
        XCTAssertEqual(level.readings, 3)
        XCTAssertFalse(level.isProvisional)
        let thin = try XCTUnwrap(LongTermGoalMath.level(samples: readings, now: at(100), windowDays: 3, minValues: 5))
        XCTAssertTrue(thin.isProvisional)
    }

    func testLevelFallsBackToTheLatestReadingProvisionally() throws {
        let old = samples([30, 31], endingAt: 40)
        let level = try XCTUnwrap(LongTermGoalMath.level(samples: old, now: at(100), windowDays: 14, minValues: 3))
        XCTAssertEqual(level.value, 31, accuracy: 1e-9)
        XCTAssertTrue(level.isProvisional)
        XCTAssertNil(LongTermGoalMath.level(samples: [], now: at(100), windowDays: 14, minValues: 3))
    }
}
