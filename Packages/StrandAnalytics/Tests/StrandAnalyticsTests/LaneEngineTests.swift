import XCTest
@testable import StrandAnalytics

/// Pins the one band every Training Load surface shows, and the verdict table built on it.
///
/// The band tests are about CONSISTENCY — one axis, edges that can be traced to their source, guards
/// that keep a sparse history from reading as an overload. The verdict tests are about RESTRAINT: a band
/// alone never earns a judgement, and a lane with no performance evidence is only ever described.
final class LaneEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// Consecutive days from `start`, each block a number of days at one daily load.
    private func series(_ blocks: [(days: Int, perDay: Double)], startingAt start: String = "2026-03-01")
    -> (daily: [String: Double], last: String) {
        var daily: [String: Double] = [:]
        var cursor = start
        var last = start
        for block in blocks {
            for _ in 0..<block.days {
                if block.perDay > 0 { daily[cursor] = block.perDay }
                last = cursor
                cursor = WeeklyDigestEngine.addDays(cursor, 1)
            }
        }
        return (daily, last)
    }

    /// One session of `minutes` on every day that carries load.
    private func activity(_ daily: [String: Double], minutes: Double = 60) -> LaneActivity {
        LaneActivity(sessionsByDay: daily.mapValues { _ in 1 }, minutesByDay: daily.mapValues { _ in minutes })
    }

    private func reading(_ s: (daily: [String: Double], last: String), lane: TrainingLaneKind = .cardio,
                         unknown: Set<String> = [], minutes: Double = 60) -> LaneReading {
        LaneEngine.reading(dailyByDay: s.daily, unknownDays: unknown, activity: activity(s.daily, minutes: minutes),
                           lane: lane, through: s.last)
    }

    // MARK: - Edges

    /// The two outer edges are Polar's 0.8 and 1.3 moved onto NOOP's uncoupled windows, where Polar's
    /// 28-day tolerance also contains the acute week: coupled = 4u / (u + 3).
    func testTheOuterEdgesArePolarsOnUncoupledWindows() {
        func coupled(_ u: Double) -> Double { 4 * u / (u + 3) }
        XCTAssertEqual(coupled(LaneEngine.provisionalBelow), 0.8, accuracy: 0.01)
        XCTAssertEqual(coupled(LaneEngine.wellAboveCeiling), 1.3, accuracy: 0.01)
    }

    func testProvisionalBandBoundaries() {
        let edges = LaneEngine.provisionalThresholds
        XCTAssertEqual(LaneEngine.band(ratio: 0.7499, thresholds: edges), .below)
        XCTAssertEqual(LaneEngine.band(ratio: 0.75, thresholds: edges), .usual)
        XCTAssertEqual(LaneEngine.band(ratio: 1.15, thresholds: edges), .usual)
        XCTAssertEqual(LaneEngine.band(ratio: 1.1501, thresholds: edges), .higher)
        XCTAssertEqual(LaneEngine.band(ratio: 1.44, thresholds: edges), .higher)
        XCTAssertEqual(LaneEngine.band(ratio: 1.4401, thresholds: edges), .muchHigher)
    }

    func testASteadyHistoryIsUsual() {
        let r = reading(series([(35, 10)]))
        XCTAssertEqual(r.trend?.ratio ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(r.band, .usual)
        XCTAssertEqual(r.guardState, .none)
    }

    /// Eight complete weeks of irregular training give wide personal edges, but a week well above the
    /// usual level still reads "well above": the personal range may not push that edge past 1.44.
    func testAPersonalRangeNeverLetsWellAboveStartPastTheCeiling() {
        // One session at the start of each seven-day chunk that the eight-week range is read in.
        let weekly: [Double] = [50, 90, 60, 100, 40, 80, 70]
        var daily: [String: Double] = [:]
        for (index, total) in weekly.enumerated() {
            daily[WeeklyDigestEngine.addDays("2026-03-01", index * 7)] = total
        }
        let baselineWeek = (100 + 40 + 80 + 70) / 4.0
        daily[WeeklyDigestEngine.addDays("2026-03-01", 49)] = baselineWeek * 1.6
        let last = WeeklyDigestEngine.addDays("2026-03-01", 55)

        let r = LaneEngine.reading(dailyByDay: daily, activity: activity(daily, minutes: 200), lane: .cardio,
                                   through: last)
        XCTAssertEqual(r.relative.maturity, .personalBaseline)
        XCTAssertEqual(r.thresholds?.isPersonal, true)
        // Unbounded, this wearer's "well above" would start near 1.78.
        let range = try? XCTUnwrap(r.relative.personalRange)
        XCTAssertGreaterThan((range?.muchHigherBound ?? 0) / baselineWeek, 1.7)
        XCTAssertEqual(r.thresholds?.wellAbove, LaneEngine.wellAboveCeiling)
        XCTAssertEqual(r.trend?.ratio ?? 0, 1.6, accuracy: 1e-9)
        XCTAssertEqual(r.band, .muchHigher)
    }

    /// A very regular history has a tiny weekly spread. Unbounded, +13 % would read "well above usual";
    /// the personal edges may not start sooner than +15 % (well above) or −10 % (below).
    func testAPersonalRangeIsNeverNarrowerThanItsFloors() {
        let weekly: [Double] = [70, 71, 69, 70, 72, 68, 70]
        var daily: [String: Double] = [:]
        for (index, total) in weekly.enumerated() {
            daily[WeeklyDigestEngine.addDays("2026-03-01", index * 7)] = total
        }
        daily[WeeklyDigestEngine.addDays("2026-03-01", 49)] = 70 * 1.13
        let last = WeeklyDigestEngine.addDays("2026-03-01", 55)

        let r = LaneEngine.reading(dailyByDay: daily, activity: activity(daily, minutes: 200), lane: .cardio,
                                   through: last)
        XCTAssertEqual(r.relative.maturity, .personalBaseline)
        XCTAssertEqual(r.thresholds?.wellAbove, LaneEngine.personalWellAboveFloor)
        XCTAssertEqual(r.thresholds?.below, LaneEngine.personalBelowCeiling)
        XCTAssertEqual(r.trend?.ratio ?? 0, 1.13, accuracy: 1e-9)
        XCTAssertEqual(r.band, .higher)
    }

    // MARK: - Guards

    /// Two sessions in the baseline are not a pattern to compare with.
    func testTooFewBaselineSessionsWithholdTheBand() {
        var daily: [String: Double] = [:]
        for offset in [9, 19, 30, 33] { daily[WeeklyDigestEngine.addDays("2026-03-01", offset)] = 60 }
        let last = WeeklyDigestEngine.addDays("2026-03-01", 34)
        let r = LaneEngine.reading(dailyByDay: daily, activity: activity(daily), lane: .cardio, through: last)
        XCTAssertNotNil(r.trend, "the comparison itself is still shown")
        XCTAssertEqual(r.guardState, .tooFewSessions)
        XCTAssertNil(r.band)
    }

    /// The beginner the old scale called overreaching: one easy session a week, then two. A return to
    /// training under the WHO minimum reads "above usual", never "well above".
    func testALowVolumeBaselineStopsAtAbove() {
        var daily: [String: Double] = [:]
        for week in 0..<5 { daily[WeeklyDigestEngine.addDays("2026-03-01", week * 7)] = 60 }
        daily[WeeklyDigestEngine.addDays("2026-03-01", 31)] = 60
        let last = WeeklyDigestEngine.addDays("2026-03-01", 34)

        let cardio = LaneEngine.reading(dailyByDay: daily, activity: activity(daily, minutes: 45), lane: .cardio,
                                        through: last)
        XCTAssertEqual(cardio.trend?.ratio ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(cardio.guardState, .lowVolumeCap)
        XCTAssertEqual(cardio.band, .higher)

        let strength = LaneEngine.reading(dailyByDay: daily, activity: activity(daily), lane: .strength,
                                          through: last)
        XCTAssertEqual(strength.guardState, .lowVolumeCap, "one strength day a week is under the WHO two")
        XCTAssertEqual(strength.band, .higher)

        // The same doubling on a baseline that already meets the minimum is an overload.
        let trained = LaneEngine.reading(dailyByDay: daily, activity: activity(daily, minutes: 200),
                                         lane: .cardio, through: last)
        XCTAssertEqual(trained.guardState, .none)
        XCTAssertEqual(trained.band, .muchHigher)
    }

    // MARK: - Hysteresis

    func testABandIsOnlyLeftFivePointsPastItsEdge() {
        let edges = LaneEngine.provisionalThresholds
        XCTAssertFalse(LaneEngine.leaves(.usual, towards: .higher, ratio: 1.19, thresholds: edges))
        XCTAssertTrue(LaneEngine.leaves(.usual, towards: .higher, ratio: 1.21, thresholds: edges))
        XCTAssertFalse(LaneEngine.leaves(.higher, towards: .usual, ratio: 1.11, thresholds: edges))
        XCTAssertTrue(LaneEngine.leaves(.higher, towards: .usual, ratio: 1.09, thresholds: edges))
        XCTAssertFalse(LaneEngine.leaves(.usual, towards: .below, ratio: 0.71, thresholds: edges))
        XCTAssertTrue(LaneEngine.leaves(.usual, towards: .below, ratio: 0.69, thresholds: edges))
    }

    /// A single heavier day that lifts the week just past the edge does not relabel it; a clear jump does.
    func testOneDayJustPastTheEdgeKeepsTheBand() {
        var nudged = series([(35, 10)])
        nudged.daily[nudged.last] = 10 + 0.18 * 70
        XCTAssertEqual(reading(nudged).trend?.ratio ?? 0, 1.18, accuracy: 1e-9)
        XCTAssertEqual(reading(nudged).band, .usual)

        var jumped = series([(35, 10)])
        jumped.daily[jumped.last] = 10 + 0.25 * 70
        XCTAssertEqual(reading(jumped).band, .higher)
    }

    // MARK: - The reading day

    func testTodayCountsOnlyOnceSomethingWasLogged() {
        XCTAssertEqual(LaneEngine.readingDay(today: "2026-09-24", hasActivityToday: true), "2026-09-24")
        XCTAssertEqual(LaneEngine.readingDay(today: "2026-09-24", hasActivityToday: false), "2026-09-23")
    }

    /// Daily training read before today's session: through today the empty day looks like a rest day and
    /// the week reads 14 % low; through yesterday it reads as the usual week it is.
    func testAMorningBeforeTrainingIsNotARestDay() {
        var s = series([(36, 10)])
        let today = s.last
        s.daily[today] = nil
        let throughToday = LaneEngine.reading(dailyByDay: s.daily, activity: activity(s.daily), lane: .cardio,
                                              through: today)
        XCTAssertEqual(throughToday.trend?.percentChange ?? 0, -14.2857, accuracy: 1e-3)

        let day = LaneEngine.readingDay(today: today, hasActivityToday: false)
        let closed = LaneEngine.reading(dailyByDay: s.daily, activity: activity(s.daily), lane: .cardio, through: day)
        XCTAssertEqual(closed.trend?.percentChange ?? 1, 0, accuracy: 1e-9)
    }

    /// Training every other day puts three or four sessions in any seven days, so the percentage swings
    /// by ±14 % from one day to the next whatever the reading day. The band must not follow it.
    func testAlternateDayTrainingKeepsOneBand() {
        var daily: [String: Double] = [:]
        for offset in stride(from: 0, to: 70, by: 2) { daily[WeeklyDigestEngine.addDays("2026-03-01", offset)] = 10 }
        let days = (50..<70).map { WeeklyDigestEngine.addDays("2026-03-01", $0) }
        let readings = LaneEngine.readings(dailyByDay: daily, activity: activity(daily, minutes: 60),
                                           lane: .cardio, days: days)
        XCTAssertTrue(readings.contains { ($0.trend?.percentChange ?? 0) > 10 })
        XCTAssertTrue(readings.contains { ($0.trend?.percentChange ?? 0) < -10 })
        XCTAssertEqual(Set(readings.map(\.band)), [.usual])
    }

    // MARK: - Unknown days

    /// Days the data cannot price are not rest days. Two unpriceable sessions in a steady week leave both
    /// windows and the week reads as the usual week it was; counted as rest they would read as a drop.
    func testUnpriceableDaysDoNotReadAsABreak() {
        var s = series([(42, 10)])
        var unknown: Set<String> = []
        for back in 3...4 {
            let day = WeeklyDigestEngine.addDays(s.last, -back)
            s.daily[day] = nil
            unknown.insert(day)
        }
        let honest = LaneEngine.reading(dailyByDay: s.daily, unknownDays: unknown, activity: activity(s.daily),
                                        lane: .cardio, through: s.last)
        XCTAssertEqual(honest.trend?.ratio ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(honest.band, .usual)
        XCTAssertEqual(honest.daysBelowUsual, 0)

        let asRest = LaneEngine.reading(dailyByDay: s.daily, activity: activity(s.daily), lane: .cardio,
                                        through: s.last)
        XCTAssertLessThan(asRest.trend?.ratio ?? 1, 1, "counted as rest, the same week reads lower")
    }

    /// Past what the coverage rule allows — fewer than five known recent days, or under three quarters
    /// of the baseline — the comparison is withheld rather than drawn from the days that happen to be known.
    func testTooManyUnknownDaysWithholdTheComparison() {
        var recent = series([(42, 10)])
        var unknownRecent: Set<String> = []
        for back in 3...5 {
            let day = WeeklyDigestEngine.addDays(recent.last, -back)
            recent.daily[day] = nil
            unknownRecent.insert(day)
        }
        let r = LaneEngine.reading(dailyByDay: recent.daily, unknownDays: unknownRecent,
                                   activity: activity(recent.daily), lane: .cardio, through: recent.last)
        XCTAssertNil(r.trend, "four of seven recent days known")

        var baseline = series([(42, 10)])
        var unknownBaseline: Set<String> = []
        for back in 10...17 {
            let day = WeeklyDigestEngine.addDays(baseline.last, -back)
            baseline.daily[day] = nil
            unknownBaseline.insert(day)
        }
        let b = LaneEngine.reading(dailyByDay: baseline.daily, unknownDays: unknownBaseline,
                                   activity: activity(baseline.daily), lane: .cardio, through: baseline.last)
        XCTAssertNil(b.trend, "twenty of twenty-eight baseline days known")
    }

    func testAFullyUnpriceableWeekWithholdsTheComparison() {
        var s = series([(42, 10)])
        var unknown: Set<String> = []
        for back in 0...6 {
            let day = WeeklyDigestEngine.addDays(s.last, -back)
            s.daily[day] = nil
            unknown.insert(day)
        }
        let r = LaneEngine.reading(dailyByDay: s.daily, unknownDays: unknown, activity: activity(s.daily),
                                   lane: .cardio, through: s.last)
        XCTAssertNil(r.trend)
        XCTAssertNil(r.band)
    }

    // MARK: - Runs and phases

    /// A build then a week off: the drop follows a high phase.
    func testAWeekOffAfterABuildFollowsAHighPhase() {
        let r = reading(series([(28, 10), (14, 16), (7, 0.5)]))
        XCTAssertEqual(r.band, .below)
        XCTAssertTrue(r.followsHighPhase)
        XCTAssertEqual(LaneEngine.verdict(r, evidence: .none, recovery: .unknown, lane: .cardio),
                       .status(.recovering))
    }

    /// A break after ordinary steady weeks is not a phase to recover from, and ten days of it is still a
    /// break rather than a loss of fitness.
    func testABreakAfterSteadyWeeksIsDescribedUntilTheWaitRunsOut() {
        let short = reading(series([(35, 10), (10, 0.5)]))
        XCTAssertEqual(short.band, .below)
        XCTAssertFalse(short.followsHighPhase)
        XCTAssertLessThan(short.daysBelowUsual, TrainingStatusModel.cardioDetrainingAfterDays)
        XCTAssertEqual(LaneEngine.verdict(short, evidence: .none, recovery: .unknown, lane: .cardio),
                       .loadOnly(.below))

        let long = reading(series([(35, 10), (24, 0.5)]))
        XCTAssertGreaterThanOrEqual(long.daysBelowUsual, TrainingStatusModel.cardioDetrainingAfterDays)
        XCTAssertEqual(LaneEngine.verdict(long, evidence: .none, recovery: .unknown, lane: .cardio),
                       .status(.detraining))
    }

    // MARK: - Bounded dependency

    /// Screens that read a longer window must show the same reading: history older than
    /// `dependencyDays` can never move it.
    func testHistoryOlderThanTheDependencyWindowCannotMoveAReading() {
        var long: [String: Double] = [:]
        var cursor = "2025-06-01"
        var index = 0
        while cursor <= "2026-03-31" {
            let value = Double((index * 37) % 23)
            if value > 4 { long[cursor] = value }
            index += 1
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }
        let day = "2026-03-31"
        let first = WeeklyDigestEngine.addDays(day, -(LaneEngine.dependencyDays - 1))
        let short = long.filter { $0.key >= first }
        for lane in TrainingLaneKind.allCases {
            let full = LaneEngine.reading(dailyByDay: long, activity: activity(long), lane: lane, through: day)
            let bounded = LaneEngine.reading(dailyByDay: short, activity: activity(short), lane: lane, through: day)
            XCTAssertEqual(full, bounded, "\(lane)")
        }
    }

    // MARK: - The verdict table

    private func verdict(_ band: RelativeLoadBand, _ evidence: LaneEvidence, recovery: RecoveryState = .holding,
                         high: Bool = false, below: Int = 0, lane: TrainingLaneKind = .strength) -> LaneVerdict {
        LaneEngine.verdict(band: band, evidence: evidence, recovery: recovery, followsHighPhase: high,
                           daysBelowUsual: below, lane: lane)
    }

    func testTheVerdictTable() {
        XCTAssertEqual(verdict(.below, .rising), .status(.maintaining))
        XCTAssertEqual(verdict(.below, .unclear), .status(.maintaining))
        XCTAssertEqual(verdict(.below, .falling), .status(.detraining))
        XCTAssertEqual(verdict(.below, .none), .loadOnly(.below))

        for band in [RelativeLoadBand.usual, .higher] {
            XCTAssertEqual(verdict(band, .rising), .status(.productive))
            XCTAssertEqual(verdict(band, .unclear), .status(.maintaining))
            XCTAssertEqual(verdict(band, .falling), .status(.unproductive))
            XCTAssertEqual(verdict(band, .none), .loadOnly(band))
        }

        XCTAssertEqual(verdict(.muchHigher, .rising, recovery: .holding), .status(.productive))
        XCTAssertEqual(verdict(.muchHigher, .rising, recovery: .strained), .status(.overreaching))
        XCTAssertEqual(verdict(.muchHigher, .rising, recovery: .unknown), .status(.overreaching))
        XCTAssertEqual(verdict(.muchHigher, .unclear, recovery: .holding), .status(.unproductive))
        XCTAssertEqual(verdict(.muchHigher, .unclear, recovery: .unknown), .status(.overreaching))
        XCTAssertEqual(verdict(.muchHigher, .falling, recovery: .holding), .status(.overreaching))
        XCTAssertEqual(verdict(.muchHigher, .none, recovery: .strained), .status(.overreaching))
        XCTAssertEqual(verdict(.muchHigher, .none, recovery: .holding), .loadOnly(.muchHigher))
        XCTAssertEqual(verdict(.muchHigher, .none, recovery: .unknown), .loadOnly(.muchHigher))
    }

    /// The table's promise: a judgement that the training is working, holding or wasted needs evidence.
    /// Without it a lane is described — or, for the decline cases, judged by time and recovery alone.
    func testNoEvidenceNeverEarnsAJudgementOfTheTraining() {
        for band in [RelativeLoadBand.below, .usual, .higher, .muchHigher] {
            for recovery in [RecoveryState.holding, .strained, .unknown] {
                for high in [false, true] {
                    for below in [0, 30] {
                        for lane in TrainingLaneKind.allCases {
                            let v = verdict(band, .none, recovery: recovery, high: high, below: below, lane: lane)
                            XCTAssertFalse([.status(.productive), .status(.maintaining), .status(.unproductive)]
                                .contains(v), "\(band) \(recovery) \(high) \(below) \(lane) gave \(v)")
                        }
                    }
                }
            }
        }
    }

    /// Bosquet et al. 2013 (strength, from the third week) and Mujika & Padilla 2000 (aerobic, after about
    /// a fortnight): each lane waits its own time before a quiet spell is called detraining.
    func testEachLaneWaitsItsOwnTimeBeforeDetraining() {
        XCTAssertEqual(verdict(.below, .unclear, below: 20, lane: .strength), .status(.maintaining))
        XCTAssertEqual(verdict(.below, .unclear, below: 21, lane: .strength), .status(.detraining))
        XCTAssertEqual(verdict(.below, .none, below: 13, lane: .cardio), .loadOnly(.below))
        XCTAssertEqual(verdict(.below, .none, below: 14, lane: .cardio), .status(.detraining))
        XCTAssertEqual(verdict(.below, .falling, below: 1, lane: .cardio), .status(.detraining))
        XCTAssertEqual(verdict(.below, .rising, below: 40, lane: .strength), .status(.maintaining))
    }

    func testBelowUsualAfterAHighPhaseIsRecoveringWhateverTheEvidence() {
        for evidence in [LaneEvidence.rising, .unclear, .falling, .none] {
            XCTAssertEqual(verdict(.below, evidence, high: true, below: 40), .status(.recovering))
        }
    }

    func testEvidenceFollowsItsSources() {
        XCTAssertEqual(LaneEvidence(StrengthResponse.unknown), .none)
        XCTAssertEqual(LaneEvidence(StrengthResponse.rising), .rising)
        XCTAssertEqual(LaneEvidence(FitnessDirection.worsening), .falling)
        XCTAssertEqual(LaneEvidence(FitnessDirection.unknown), .none)
    }

    // MARK: - Weekly bands

    func testWeeklyBandsAreReadAsOfEachWeekEnd() {
        let s = series([(28, 10), (14, 16), (7, 0.5)])
        let days = TrainingStatusModel.weekEnds(weeks: 4, through: s.last)
        XCTAssertEqual(days.last, s.last)
        let cardio = LaneEngine.readings(dailyByDay: s.daily, activity: activity(s.daily), lane: .cardio, days: days)
        let bands = TrainingStatusModel.weeklyBands(strength: [], cardio: cardio)
        XCTAssertEqual(bands.map(\.day), days)
        XCTAssertEqual(bands.last?.cardio, .below)
        XCTAssertTrue(bands.dropLast().contains { $0.cardio == .higher || $0.cardio == .muchHigher })
        XCTAssertTrue(bands.allSatisfy { $0.strength == nil })
    }
}
