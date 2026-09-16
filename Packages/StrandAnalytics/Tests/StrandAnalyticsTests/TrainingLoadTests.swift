import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the three training-load figures and the comparison that reads them.
///
/// The defining property is the ORDERING: a load metric that ranks an easy high-rep session above a
/// heavy top-end one is worse than no metric, because it points training in the wrong direction.
final class TrainingLoadTests: XCTestCase {
    func testProvisionalStrengthRingUsesCompleteSessionLoadWindow() {
        let reading = TrainingLoad.provisionalStrengthRing(
            sessionLoads: [840, 840, 840], weightedMuscleSets: ["chest": 2])

        XCTAssertEqual(reading?.source, .provisionalSessionLoad)
        XCTAssertEqual(reading?.band, .veryHigh)
        XCTAssertEqual(reading?.value, 2_520)
        XCTAssertEqual(reading?.fraction, 1)
        XCTAssertFalse(reading?.isLowerBound ?? true)
    }

    func testMissingOneSessionRatingSwitchesWholeWindowToMuscleSets() {
        let reading = TrainingLoad.provisionalStrengthRing(
            sessionLoads: [420, nil, 350],
            weightedMuscleSets: ["chest": 12, "triceps": 6], hasUnmappedSets: true)

        XCTAssertEqual(reading?.source, .provisionalWeightedSets)
        XCTAssertEqual(reading?.band, .high)
        XCTAssertEqual(reading?.value, 12)
        XCTAssertTrue(reading?.isLowerBound ?? false)
    }

    func testProvisionalStrengthRingRequiresARealSessionAndPositiveEvidence() {
        XCTAssertNil(TrainingLoad.provisionalStrengthRing(sessionLoads: [],
                                                           weightedMuscleSets: ["chest": 20]))
        XCTAssertNil(TrainingLoad.provisionalStrengthRing(sessionLoads: [nil],
                                                           weightedMuscleSets: [:]))
    }

    func testRelativeLoadMaturesWithoutHidingTheFirstEightWeeks() throws {
        let immediate = TrainingLoad.relativeLoad(daily: Array(repeating: Optional(10.0), count: 20))
        XCTAssertEqual(immediate.maturity, .immediate)
        XCTAssertNil(immediate.trend)

        let early = TrainingLoad.relativeLoad(
            daily: Array(repeating: Optional(10.0), count: 14)
                + Array(repeating: Optional(15.0), count: 7))
        XCTAssertEqual(early.maturity, .earlyEstimate)
        XCTAssertEqual(try XCTUnwrap(early.trend).ratio, 1.5, accuracy: 1e-9)
        XCTAssertNil(early.band)

        let growing = TrainingLoad.relativeLoad(
            daily: Array(repeating: Optional(10.0), count: 28)
                + Array(repeating: Optional(12.0), count: 7))
        XCTAssertEqual(growing.maturity, .baselineGrowing)
        XCTAssertNotNil(growing.trend)
        XCTAssertNil(growing.band)
    }

    func testPersonalBaselineUsesRobustWeeklyVariation() throws {
        // Seven previous complete weeks around 70, then a current week at 105.
        let weekly = [68.0, 70, 72, 69, 71, 70, 73, 105]
        let daily: [Double?] = weekly.flatMap { week in
            Array(repeating: Optional(week / 7), count: 7)
        }
        let reading = TrainingLoad.relativeLoad(daily: daily)
        XCTAssertEqual(reading.maturity, .personalBaseline)
        XCTAssertEqual(reading.band, .muchHigher)
        XCTAssertNotNil(reading.personalRange)
    }

    func testEightFlatWeeksKeepGrowingUntilVariationCanBeEstimated() {
        let reading = TrainingLoad.relativeLoad(daily: Array(repeating: Optional(10.0), count: 56))
        XCTAssertEqual(reading.maturity, .baselineGrowing)
        XCTAssertNil(reading.personalRange)
        XCTAssertNil(reading.band)
    }

    func testIncompleteDayPreventsComparisonAndMaturity() {
        var daily: [Double?] = Array(repeating: Optional(10.0), count: 56)
        daily[52] = nil
        let reading = TrainingLoad.relativeLoad(daily: daily)
        XCTAssertEqual(reading.maturity, .baselineGrowing)
        XCTAssertNil(reading.trend, "a partial day must not be averaged away as if it were complete")
        XCTAssertNil(reading.band)
    }

    // MARK: - Strength load

    /// THE case tonnage gets wrong. Four sets of ten at 100 kg is 4 000 kg of tonnage; five triples at
    /// 180 kg is 2 700 kg — yet the triples are the harder session. Effort-weighted sets rank them the
    /// way the training actually felt.
    func testHeavyTopEndWorkOutranksEasyVolumeDespiteLessTonnage() {
        let easyVolume = TrainingLoad.strengthLoad(setRpes: [6, 6, 6.5, 7])        // 4×10 @ 100 kg
        let heavyTriples = TrainingLoad.strengthLoad(setRpes: [9, 9.5, 9.5, 10, 10]) // 5×3 @ 180 kg
        XCTAssertGreaterThan(heavyTriples.weightedSets, easyVolume.weightedSets)
        // And the tonnage those sessions would have reported, for the record:
        let easyTonnage = 4.0 * 10 * 100
        let heavyTonnage = 5.0 * 3 * 180
        XCTAssertGreaterThan(easyTonnage, heavyTonnage)
    }

    /// Ten easy sets must not equal ten hard ones — the weakness a plain set count has, and the reason
    /// the weighting exists.
    func testTenEasySetsAreNotTenHardSets() {
        let easy = TrainingLoad.strengthLoad(setRpes: Array(repeating: 6, count: 10))
        let hard = TrainingLoad.strengthLoad(setRpes: Array(repeating: 10, count: 10))
        XCTAssertEqual(easy.workingSets, hard.workingSets)
        XCTAssertLessThan(easy.weightedSets, hard.weightedSets)
        XCTAssertEqual(hard.weightedSets, 10, accuracy: 1e-9)
    }

    /// The weighting is the SAME curve the muscle map prices sets with. Two RPE weightings in one app
    /// would let two screens disagree about how hard the same set was.
    func testTheWeightingIsTheOneTheMuscleMapAlreadyUses() {
        for rpe in [5.0, 6.0, 7.5, 9.0, 10.0] {
            let load = TrainingLoad.strengthLoad(setRpes: [rpe])
            XCTAssertEqual(load.weightedSets, MuscleStimulus.proximityFactor(rpe: rpe), accuracy: 1e-12)
        }
    }

    /// An unrated set takes the documented default rather than counting as full effort. Assuming every
    /// unlogged set went to failure would inflate exactly the people who log least.
    func testAnUnratedSetDoesNotCountAsFailure() {
        let unrated = TrainingLoad.strengthLoad(setRpes: [nil, nil, nil])
        XCTAssertLessThan(unrated.weightedSets, 3)
        XCTAssertEqual(unrated.ratedShare, 0)
        XCTAssertTrue(unrated.isMostlyUnrated)
    }

    /// Coverage is reported so a screen can say when the weighting is mostly assumption.
    func testCoverageIsReported() {
        let mixed = TrainingLoad.strengthLoad(setRpes: [8, 8, nil, nil])
        XCTAssertEqual(mixed.ratedShare, 0.5, accuracy: 1e-9)
        XCTAssertFalse(mixed.isMostlyUnrated)
        XCTAssertTrue(TrainingLoad.strengthLoad(setRpes: [8, nil, nil, nil]).isMostlyUnrated)
    }

    /// The rated COUNT travels with the share, so a screen can say "3 of 4 sets" rather than a
    /// percentage that hides how few sets it rests on.
    func testRatedSetsAreCounted() {
        let mixed = TrainingLoad.strengthLoad(setRpes: [8, nil, 9, 7])
        XCTAssertEqual(mixed.ratedSets, 3)
        XCTAssertEqual(mixed.workingSets, 4)
        XCTAssertEqual(TrainingLoad.strengthLoad(setRpes: []).ratedSets, 0)
    }

    /// The daily series may only borrow ratings that existed before that day. Pooling the whole query
    /// would leak future ratings backwards and rewrite an earlier unknown set.
    func testDailyStrengthLoadDoesNotBorrowFutureRatings() {
        func makeSet(_ index: Int, _ type: HevySetType, rpe: Double?) -> HevySet {
            HevySet(index: index, type: type, weightKg: 100, reps: 5,
                    distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
        }
        func makeWorkout(_ id: String, _ startTs: Int, _ sets: [HevySet]) -> HevyWorkout {
            let squat = HevyExercise(index: 0, title: "Squat", templateId: nil,
                                     supersetId: nil, notes: nil, sets: sets)
            return HevyWorkout(id: id, title: "", routineId: nil, notes: nil,
                               startTs: startTs, endTs: startTs + 3600,
                               updatedAtTs: startTs, createdAtTs: startTs, exercises: [squat])
        }
        let firstSets: [HevySet] = [makeSet(0, .warmup, rpe: nil), makeSet(1, .normal, rpe: 9),
                                    makeSet(2, .normal, rpe: nil)]
        let secondSets: [HevySet] = [makeSet(0, .normal, rpe: 8), makeSet(1, .failure, rpe: 10)]
        let day = 86_400
        let workouts: [HevyWorkout] = [makeWorkout("a", 1_788_282_000, firstSets),
                                       makeWorkout("b", 1_788_282_000 + 2 * day, secondSets)]
        let pooled = StrengthSession.strengthLoad(workouts)
        XCTAssertEqual(pooled.workingSets, 4)
        XCTAssertEqual(pooled.ratedSets, 3)
        let daily = StrengthSession.weightedSetsByDay(workouts).values.reduce(0, +)
        XCTAssertEqual(daily, 3.12, accuracy: 1e-12)
        XCTAssertNotEqual(pooled.weightedSets, daily)
    }

    // MARK: - Session load

    /// Foster's method: session RPE times minutes.
    func testSessionLoadIsRpeTimesMinutes() {
        let load = TrainingLoad.sessionLoad([(rpe: 8, minutes: 75), (rpe: 6, minutes: 40)])
        XCTAssertEqual(load.arbitraryUnits, 8 * 75 + 6 * 40, accuracy: 1e-9)
        XCTAssertEqual(load.ratedSessions, 2)
    }

    /// A session nobody rated is counted but not priced. Giving it an average would put invented work
    /// into the one figure whose entire value is that the athlete supplied it.
    func testAnUnratedSessionIsCountedButNotPriced() {
        let load = TrainingLoad.sessionLoad([(rpe: 8, minutes: 60), (rpe: nil, minutes: 90)])
        XCTAssertEqual(load.arbitraryUnits, 480, accuracy: 1e-9)
        XCTAssertEqual(load.ratedSessions, 1)
        XCTAssertEqual(load.totalSessions, 2)
    }

    // MARK: - Trend

    /// The headline is a signed percentage, not a ratio to look up.
    func testTheTrendReportsASignedPercentage() throws {
        // 28 quiet baseline days at 2.0, then 7 recent days at 3.0.
        let daily = Array(repeating: 2.0, count: 28) + Array(repeating: 3.0, count: 7)
        let trend = try XCTUnwrap(TrainingLoad.trend(daily: daily))
        XCTAssertEqual(trend.recentPerDay, 3.0, accuracy: 1e-9)
        XCTAssertEqual(trend.baselinePerDay, 2.0, accuracy: 1e-9)
        XCTAssertEqual(trend.percentChange, 50, accuracy: 0.01)
        // The ratio is still available for callers that need it.
        XCTAssertEqual(trend.ratio, 1.5, accuracy: 1e-9)
    }

    /// The recent week must not dilute its own comparator. This is the coupled-ratio failure mode:
    /// including the seven high days in the 28-day mean would produce 1.33 instead of 1.5.
    func testRecentWeekIsExcludedFromItsBaseline() throws {
        let daily = Array(repeating: 2.0, count: 28) + Array(repeating: 3.0, count: 7)
        XCTAssertEqual(try XCTUnwrap(TrainingLoad.trend(daily: daily)).ratio, 1.5, accuracy: 1e-9)
    }

    /// A quiet week reads negative.
    func testAQuietWeekReadsNegative() throws {
        let daily = Array(repeating: 4.0, count: 28) + Array(repeating: 1.0, count: 7)
        let trend = try XCTUnwrap(TrainingLoad.trend(daily: daily))
        XCTAssertLessThan(trend.percentChange, 0)
    }

    /// Rest days are real zeros. Someone who trained twice must not look like someone who trained six
    /// times — that is the whole difference between load and session intensity.
    func testRestDaysCountAsZero() throws {
        let twice = Array(repeating: 0.0, count: 35).enumerated().map { i, _ in
            [5, 12].contains(i % 14) ? 6.0 : 0.0
        }
        let often = Array(repeating: 0.0, count: 35).enumerated().map { i, _ in
            i % 14 < 6 ? 6.0 : 0.0
        }
        XCTAssertLessThan(try XCTUnwrap(TrainingLoad.trend(daily: twice)).baselinePerDay,
                          try XCTUnwrap(TrainingLoad.trend(daily: often)).baselinePerDay)
    }

    /// Too little history produces nothing, and a first fortnight is not "infinitely above usual".
    func testThinHistoryProducesNothing() {
        XCTAssertNil(TrainingLoad.trend(daily: Array(repeating: 3.0, count: 20)))
        XCTAssertNil(TrainingLoad.trend(daily: Array(repeating: 0.0, count: 35)))
    }

    func testSparseDatedTrendFillsRestDaysWithZero() throws {
        var values: [String: Double] = [:]
        var day = "2026-08-01"
        for index in 0..<35 {
            if index.isMultiple(of: 2) { values[day] = index < 28 ? 10 : 20 }
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let trend = try XCTUnwrap(TrainingLoad.trend(dailyByDay: values, through: "2026-09-04"))
        // Four even-indexed training days fall in the final seven-day window.
        XCTAssertEqual(trend.recentPerDay, 80.0 / 7.0, accuracy: 1e-9)
    }

    func testTwoBaselineWeeksPlusARecentWeekDoNotInventEarlierRestDays() throws {
        var values: [String: Double] = [:]
        var day = "2026-08-01"
        for _ in 0..<21 {
            values[day] = 10
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let trend = try XCTUnwrap(TrainingLoad.trend(dailyByDay: values, through: "2026-08-21"))
        XCTAssertEqual(trend.recentPerDay, 10, accuracy: 1e-9)
        XCTAssertEqual(trend.baselinePerDay, 10, accuracy: 1e-9)
        XCTAssertEqual(trend.percentChange, 0, accuracy: 1e-9)
        XCTAssertNil(TrainingLoad.trend(dailyByDay: values, through: "2026-08-14"))
    }

    // MARK: - Unrated sets take the athlete's own median

    /// Rating MORE sets must not, on its own, move the weekly load once the athlete has a usable
    /// historical median. Current-set ratings are not borrowed to fill their neighbours.
    func testRatingHabitAloneDoesNotMoveTheLoad() {
        let history = [8.0, 8, 8]
        let allRated = TrainingLoad.strengthLoad(setRpes: [8, 8, 8, 8, 8, 8], historicalRpes: history)
        let halfLogged = TrainingLoad.strengthLoad(setRpes: [8, 8, 8, nil, nil, nil], historicalRpes: history)
        XCTAssertEqual(halfLogged.weightedSets, allRated.weightedSets, accuracy: 1e-9)
    }

    func testUnratedSetsUseTheSeparateTwentyEightDayHistoryPool() {
        let current = TrainingLoad.strengthLoad(setRpes: [nil, nil], historicalRpes: [6, 6, 6])
        XCTAssertEqual(current.weightedSets,
                       2 * MuscleStimulus.proximityFactor(rpe: 6), accuracy: 1e-12)
        XCTAssertTrue(current.usedPersonalUnratedEstimate)
    }

    /// The borrowed historical weight follows the athlete: someone whose logged sets are easy has easy unrated
    /// sets, and someone who grinds every set has hard ones.
    func testTheBorrowedWeightFollowsTheAthlete() {
        let easyLogger = TrainingLoad.strengthLoad(setRpes: [nil, nil], historicalRpes: [6, 6, 6])
        let hardLogger = TrainingLoad.strengthLoad(setRpes: [nil, nil], historicalRpes: [10, 10, 10])
        XCTAssertLessThan(easyLogger.weightedSets, hardLogger.weightedSets)
        XCTAssertEqual(easyLogger.ratedShare, hardLogger.ratedShare, accuracy: 1e-12)
    }

    /// Too little prior history keeps the neutral start estimate, even when the current session has a
    /// rated set. This prevents one unusually hard set from filling every unknown set as hard.
    func testTheNeutralDefaultAppliesUntilHistoryIsSufficient() {
        let load = TrainingLoad.strengthLoad(setRpes: [10, nil], historicalRpes: [10, 10])
        XCTAssertEqual(load.weightedSets, 1 + TrainingLoad.neutralUnratedWeight, accuracy: 1e-12)
        XCTAssertFalse(load.usedPersonalUnratedEstimate)
    }

    // MARK: - Days the data cannot speak for

    /// A day that could not be priced is not a rest day. Scoring it zero is the difference between
    /// "you trained less" and "we could not measure what you did" — and only the second is true.
    func testUnmeasuredDaysAreNotRestDays() throws {
        var withGaps: [Double?] = Array(repeating: 4.0, count: 35).map { Optional($0) }
        for index in 28..<32 { withGaps[index] = nil }
        XCTAssertEqual(try XCTUnwrap(TrainingLoad.trend(daily: withGaps)).percentChange, 0, accuracy: 1e-9)

        var asZeros = Array(repeating: 4.0, count: 35)
        for index in 28..<32 { asZeros[index] = 0 }
        XCTAssertLessThan(try XCTUnwrap(TrainingLoad.trend(daily: asZeros)).percentChange, -40)
    }

    /// The dated form drops the days it is given by name — and only those. A day nobody named is still
    /// a rest day, because a rest day is real training information.
    func testDatedUnknownDaysDropOutAndOthersStayZero() throws {
        var values: [String: Double] = [:]
        var unmeasured: Set<String> = []
        var day = "2026-08-01"
        for index in 0..<35 {
            values[day] = 4
            if (31...33).contains(index) { unmeasured.insert(day) }
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let measured = values.filter { !unmeasured.contains($0.key) }
        let dropped = try XCTUnwrap(TrainingLoad.trend(dailyByDay: measured, through: "2026-09-04",
                                                       unknownDays: unmeasured))
        XCTAssertEqual(dropped.recentPerDay, 4, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(TrainingLoad.trend(dailyByDay: measured, through: "2026-09-04")).recentPerDay, 4)
    }

    // MARK: - The shape of a week

    /// Two weeks can carry the same total and feel nothing alike. Monotony separates one huge session
    /// from the same load spread across the week — higher means flatter and more repetitive.
    func testMonotonySeparatesSpikesFromEvenWeeks() throws {
        let spiky = try XCTUnwrap(TrainingLoad.distribution(daily: [600, 0, 0, 0, 0, 0, 0]))
        let even = try XCTUnwrap(TrainingLoad.distribution(daily: [120, 90, 100, 80, 110, 60, 40]))
        XCTAssertEqual(spiky.total, 600, accuracy: 1e-9)
        XCTAssertEqual(even.total, 600, accuracy: 1e-9)
        XCTAssertGreaterThan(even.monotony, spiky.monotony)
        XCTAssertEqual(even.strain, even.total * even.monotony, accuracy: 1e-9)
    }

    /// A week with no spread at all makes monotony infinite. "Infinitely repetitive" is a division
    /// artefact, not a description of a week, so nothing is reported — as with too few known days.
    func testNoDistributionWithoutSpreadOrEnoughDays() {
        XCTAssertNil(TrainingLoad.distribution(daily: Array(repeating: Optional(80.0), count: 7)))
        XCTAssertNil(TrainingLoad.distribution(daily: [100, nil, nil, nil, 90, nil, 80]))
    }

    // MARK: - Week over week

    /// The plain companion to the ratio: two weeks that do not overlap, and no threshold to look up.
    func testWeekOverWeekComparesTwoDistinctWeeks() throws {
        let daily: [Double?] = Array(repeating: 10.0, count: 7) + Array(repeating: 13.0, count: 7)
        XCTAssertEqual(try XCTUnwrap(TrainingLoad.weekOverWeek(daily: daily)), 30, accuracy: 1e-9)
    }

    /// Nothing to compare against produces nothing: one week of history, or a first week from zero.
    func testWeekOverWeekWithholdsWhatItCannotCompare() {
        XCTAssertNil(TrainingLoad.weekOverWeek(daily: Array(repeating: Optional(10.0), count: 7)))
        let fromNothing: [Double?] = Array(repeating: 0.0, count: 7) + Array(repeating: 5.0, count: 7)
        XCTAssertNil(TrainingLoad.weekOverWeek(daily: fromNothing))
    }
}
