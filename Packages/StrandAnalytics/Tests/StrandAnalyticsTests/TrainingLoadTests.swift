import XCTest
@testable import StrandAnalytics

/// Pins the three training-load figures and the comparison that reads them.
///
/// The defining property is the ORDERING: a load metric that ranks an easy high-rep session above a
/// heavy top-end one is worse than no metric, because it points training in the wrong direction.
final class TrainingLoadTests: XCTestCase {

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
        // 21 quiet days at 2.0, then 7 days at 3.0.
        let daily = Array(repeating: 2.0, count: 21) + Array(repeating: 3.0, count: 7)
        let trend = try XCTUnwrap(TrainingLoad.trend(daily: daily))
        XCTAssertEqual(trend.recentPerDay, 3.0, accuracy: 1e-9)
        XCTAssertEqual(trend.baselinePerDay, 2.25, accuracy: 1e-9)
        XCTAssertEqual(trend.percentChange, 33.333, accuracy: 0.01)
        // The ratio is still available for callers that need it.
        XCTAssertEqual(trend.ratio, 3.0 / 2.25, accuracy: 1e-9)
    }

    /// A quiet week reads negative.
    func testAQuietWeekReadsNegative() throws {
        let daily = Array(repeating: 4.0, count: 21) + Array(repeating: 1.0, count: 7)
        let trend = try XCTUnwrap(TrainingLoad.trend(daily: daily))
        XCTAssertLessThan(trend.percentChange, 0)
    }

    /// Rest days are real zeros. Someone who trained twice must not look like someone who trained six
    /// times — that is the whole difference between load and session intensity.
    func testRestDaysCountAsZero() throws {
        let twice = Array(repeating: 0.0, count: 28).enumerated().map { i, _ in
            [5, 12].contains(i % 14) ? 6.0 : 0.0
        }
        let often = Array(repeating: 0.0, count: 28).enumerated().map { i, _ in
            i % 14 < 6 ? 6.0 : 0.0
        }
        XCTAssertLessThan(try XCTUnwrap(TrainingLoad.trend(daily: twice)).baselinePerDay,
                          try XCTUnwrap(TrainingLoad.trend(daily: often)).baselinePerDay)
    }

    /// Too little history produces nothing, and a first fortnight is not "infinitely above usual".
    func testThinHistoryProducesNothing() {
        XCTAssertNil(TrainingLoad.trend(daily: Array(repeating: 3.0, count: 9)))
        XCTAssertNil(TrainingLoad.trend(daily: Array(repeating: 0.0, count: 28)))
    }

    func testSparseDatedTrendFillsRestDaysWithZero() throws {
        var values: [String: Double] = [:]
        var day = "2026-08-01"
        for index in 0..<28 {
            if index.isMultiple(of: 2) { values[day] = index < 21 ? 10 : 20 }
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let trend = try XCTUnwrap(TrainingLoad.trend(dailyByDay: values, through: "2026-08-28"))
        // Aug 22, 24 and 26 are the three even-indexed training days in the final seven-day window.
        XCTAssertEqual(trend.recentPerDay, 60.0 / 7.0, accuracy: 1e-9)
    }

    func testTwoWeeksOfHistoryDoesNotInventEarlierRestDays() throws {
        var values: [String: Double] = [:]
        var day = "2026-08-01"
        for _ in 0..<14 {
            values[day] = 10
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        let trend = try XCTUnwrap(TrainingLoad.trend(dailyByDay: values, through: "2026-08-14"))
        XCTAssertEqual(trend.recentPerDay, 10, accuracy: 1e-9)
        XCTAssertEqual(trend.baselinePerDay, 10, accuracy: 1e-9)
        XCTAssertEqual(trend.percentChange, 0, accuracy: 1e-9)
    }
}
