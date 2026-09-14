import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the Training Load status: the conventional load scale for cardio, the outcome-aware table for
/// strength.
///
/// The cardio tests are about FIDELITY — the published thresholds, boundaries included. The strength
/// tests are about RESTRAINT: a ratio alone must never call a lifting block productive when the lifts are
/// falling, an unclear e1RM must not be called unproductive at the usual load, and a missing input must
/// fall back to the load-only mapping rather than invent a response.
final class TrainingStatusTests: XCTestCase {
    func testMissingPerformanceEvidenceNeverClaimsAdaptation() {
        let strength = TrainingStatusModel.strengthAdaptation(
            StrengthResponseReading(direction: .unknown, rising: 0, falling: 0, unclear: 0))
        let cardio = TrainingStatusModel.cardiovascularAdaptation(
            VO2maxResponse(direction: .unknown, readings: [], slopePerWeek: nil,
                           changeOverSpan: nil, spanDays: 0, segmentBreak: false))
        XCTAssertEqual(strength.state, .notEnoughData)
        XCTAssertEqual(cardio.state, .notEnoughData)
    }


    // MARK: - The scale

    func testBandBoundaries() {
        XCTAssertEqual(TrainingStatusModel.band(ratio: 0.79), .below)
        XCTAssertEqual(TrainingStatusModel.band(ratio: 0.8), .maintaining)
        XCTAssertEqual(TrainingStatusModel.band(ratio: 0.999), .maintaining)
        XCTAssertEqual(TrainingStatusModel.band(ratio: 1.0), .productive)
        XCTAssertEqual(TrainingStatusModel.band(ratio: 1.3), .productive)
        XCTAssertEqual(TrainingStatusModel.band(ratio: 1.3001), .above)
    }

    // MARK: - Cardio: the four load states

    func testCardioFollowsTheFourLoadStates() {
        XCTAssertEqual(TrainingStatusModel.cardioStatus(ratio: 0.6, followsRecentHighPhase: false,
                                                        daysBelowUsual: 20), .detraining)
        XCTAssertEqual(TrainingStatusModel.cardioStatus(ratio: 0.9, followsRecentHighPhase: false), .maintaining)
        XCTAssertEqual(TrainingStatusModel.cardioStatus(ratio: 1.15, followsRecentHighPhase: false), .productive)
        XCTAssertEqual(TrainingStatusModel.cardioStatus(ratio: 1.4, followsRecentHighPhase: false), .overreaching)
    }

    /// One quiet week is a quiet week. Aerobic capacity holds through roughly the first fortnight of
    /// reduced training, so calling day one of a deload "detraining" would name a loss the athlete has
    /// not had — and the athlete cannot tell that verdict apart from a real decline.
    func testAShortSpellBelowUsualIsNotYetDetraining() {
        for days in [0, 6, 13] {
            XCTAssertEqual(TrainingStatusModel.cardioStatus(ratio: 0.6, followsRecentHighPhase: false,
                                                            daysBelowUsual: days), .maintaining)
        }
        XCTAssertEqual(TrainingStatusModel.cardioStatus(ratio: 0.6, followsRecentHighPhase: false,
                                                        daysBelowUsual: TrainingStatusModel.cardioDetrainingAfterDays),
                       .detraining)
    }

    /// Below 0.8 right after a hard phase is a deload, not a decline.
    func testCardioBelowAfterAHighPhaseIsRecovering() {
        XCTAssertEqual(TrainingStatusModel.cardioStatus(ratio: 0.6, followsRecentHighPhase: true), .recovering)
    }

    // MARK: - Recent high phase, from a real daily series

    private func series(_ blocks: [(days: Int, perDay: Double)], startingAt start: String) -> (daily: [String: Double], last: String) {
        var daily: [String: Double] = [:]
        var cursor = start
        var last = start
        for block in blocks {
            for _ in 0..<block.days {
                daily[cursor] = block.perDay
                last = cursor
                cursor = WeeklyDigestEngine.addDays(cursor, 1)
            }
        }
        return (daily, last)
    }

    /// A build then a week off: the drop reads as recovering, and the lane status says so.
    func testAWeekOffAfterABuildIsRecovering() {
        let s = series([(28, 10), (14, 16), (7, 0.5)], startingAt: "2026-06-01")
        let lane = TrainingStatusModel.cardio(dailyByDay: s.daily, through: s.last)
        XCTAssertNotNil(lane)
        XCTAssertLessThan(lane!.ratio, 0.8)
        XCTAssertTrue(lane!.followsRecentHighPhase)
        XCTAssertEqual(lane!.status, .recovering)
    }

    /// A break after ordinary steady training is no longer read as a phase to recover from — steady
    /// training sits at exactly 1.0, so the fortnight before a 10-day break holds only four such days.
    /// It is not detraining either: ten days below usual is a break, and the lane says so plainly.
    func testATenDayBreakAfterSteadyWeeksIsNeitherRecoveringNorDetraining() {
        let s = series([(35, 10), (10, 0.5)], startingAt: "2026-06-01")
        let lane = TrainingStatusModel.cardio(dailyByDay: s.daily, through: s.last)
        XCTAssertNotNil(lane)
        XCTAssertLessThan(lane!.ratio, 0.8)
        XCTAssertFalse(lane!.followsRecentHighPhase)
        XCTAssertLessThan(lane!.daysBelowUsual, TrainingStatusModel.cardioDetrainingAfterDays)
        XCTAssertEqual(lane!.status, .maintaining)
    }

    /// Once the break outlasts the fortnight, the verdict changes on its own — the run is what decides.
    func testABreakPastTheFortnightIsDetraining() {
        let s = series([(35, 10), (24, 0.5)], startingAt: "2026-06-01")
        let lane = TrainingStatusModel.cardio(dailyByDay: s.daily, through: s.last)
        XCTAssertNotNil(lane)
        XCTAssertLessThan(lane!.ratio, 0.8)
        XCTAssertFalse(lane!.followsRecentHighPhase)
        XCTAssertGreaterThanOrEqual(lane!.daysBelowUsual, TrainingStatusModel.cardioDetrainingAfterDays)
        XCTAssertEqual(lane!.status, .detraining)
    }

    /// Forty-two steady days, four of the last seven trained but not priceable.
    private func steadyDaysWithUnpriced(_ unpricedIndices: ClosedRange<Int>)
    -> (measured: [String: Double], unmeasured: Set<String>, last: String) {
        var daily: [String: Double] = [:]
        var unmeasured: Set<String> = []
        var cursor = "2026-06-01"
        var last = cursor
        for index in 0..<42 {
            if unpricedIndices.contains(index) { unmeasured.insert(cursor) } else { daily[cursor] = 10 }
            last = cursor
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }
        return (daily, unmeasured, last)
    }

    /// Days the data cannot price are not rest days. Four unpriceable sessions in the last week must not
    /// turn a lane that trained exactly as usual into one that fell below usual — the athlete would read
    /// a gap in our measurement as a drop in their training.
    func testUnpriceableCardioDaysDoNotReadAsABreak() throws {
        let s = steadyDaysWithUnpriced(35...38)
        let honest = try XCTUnwrap(TrainingStatusModel.cardio(dailyByDay: s.measured, through: s.last,
                                                              unknownDays: s.unmeasured))
        XCTAssertEqual(honest.ratio, 1, accuracy: 1e-9)
        XCTAssertNotEqual(honest.band, .below)
        XCTAssertEqual(honest.daysBelowUsual, 0)

        // The same four days counted as rest is the failure this rule exists to prevent.
        let asRest = try XCTUnwrap(TrainingStatusModel.cardio(dailyByDay: s.measured, through: s.last))
        XCTAssertEqual(asRest.band, .below)
    }

    /// When the WHOLE recent week is unpriceable there is nothing to compare, and the lane withholds the
    /// comparison rather than inventing one from the days it happens to have.
    func testAFullyUnpriceableWeekWithholdsTheComparison() {
        let s = steadyDaysWithUnpriced(35...41)
        XCTAssertNil(TrainingStatusModel.cardio(dailyByDay: s.measured, through: s.last,
                                                unknownDays: s.unmeasured))
    }

    /// The run of below-usual days is counted from the day the ratio first dropped under 0.8. With ten
    /// days at 0.5 after steady 10s, the ratio is 0.895 on the first day of the break and 0.78 on the
    /// second, so the run on day ten is nine days.
    func testDaysBelowUsualCountsTheRun() {
        let s = series([(35, 10), (10, 0.5)], startingAt: "2026-06-01")
        XCTAssertEqual(TrainingStatusModel.daysBelowUsual(dailyByDay: s.daily, through: s.last), 9)
        XCTAssertEqual(TrainingStatusModel.cardio(dailyByDay: s.daily, through: s.last)?.daysBelowUsual, 9)
    }

    /// The history strip recomputes each week as of that week: a build shows as productive, the week
    /// off at the end as recovering — not today's verdict copied backwards.
    func testWeeklyHistoryRecomputesEachWeek() {
        let s = series([(28, 10), (14, 16), (7, 0.5)], startingAt: "2026-06-01")
        let history = TrainingStatusModel.weeklyHistory(weeks: 4, through: s.last, strengthDaily: [:],
                                                        cardioDaily: s.daily, workouts: [], templates: [:],
                                                        days: [])
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.last?.day, s.last)
        XCTAssertEqual(history.last?.cardio, .recovering)
        XCTAssertTrue(history.dropLast().contains { $0.cardio == .productive || $0.cardio == .overreaching })
        XCTAssertTrue(history.allSatisfy { $0.strength == nil })
    }

    /// No status while the load comparison itself is withheld (under two weeks of history).
    func testNoStatusWithoutAComparison() {
        let s = series([(10, 10)], startingAt: "2026-06-01")
        XCTAssertNil(TrainingStatusModel.cardio(dailyByDay: s.daily, through: s.last))
    }

    // MARK: - Strength: the decision table

    private func strength(_ ratio: Double, _ response: StrengthResponse,
                          recovery: RecoveryState = .holding, recentHigh: Bool = false,
                          daysBelow: Int = 0) -> TrainingStatus {
        TrainingStatusModel.strengthStatus(ratio: ratio, followsRecentHighPhase: recentHigh,
                                           response: response, recovery: recovery,
                                           daysBelowUsual: daysBelow)
    }

    /// Bosquet et al. 2013: maximal force is measurably lower only from the third week without training.
    /// Before that, a strength lane under its usual load with no falling lifts is still holding.
    func testStrengthIsHeldForThreeWeeksBeforeItCountsAsDetraining() {
        XCTAssertEqual(strength(0.6, .unclear, daysBelow: 20), .maintaining)
        XCTAssertEqual(strength(0.6, .unclear, daysBelow: 21), .detraining)
        XCTAssertEqual(strength(0.6, .unknown, daysBelow: 20), .maintaining)
        XCTAssertEqual(strength(0.6, .unknown, daysBelow: 21), .detraining)
        // Lifts that are visibly falling need no waiting period; lifts that rise are never detraining.
        XCTAssertEqual(strength(0.6, .falling, daysBelow: 2), .detraining)
        XCTAssertEqual(strength(0.6, .rising, daysBelow: 40), .maintaining)
    }

    /// THE case the ratio alone gets wrong: usual-or-more load with the lifts going down.
    func testLoadWithFallingLiftsIsUnproductiveNotProductive() {
        XCTAssertEqual(strength(1.15, .falling), .unproductive)
        XCTAssertEqual(strength(1.15, .rising), .productive)
    }

    /// An unclear line at the usual load is maintaining. Slow advanced progress is below what six weeks
    /// of e1RM can resolve, and "unproductive" would be a claim the data cannot make.
    func testUnclearAtTheUsualLoadIsMaintaining() {
        XCTAssertEqual(strength(1.15, .unclear), .maintaining)
        XCTAssertEqual(strength(0.9, .unclear), .maintaining)
    }

    func testBelowUsualLoadDependsOnTheLifts() {
        XCTAssertEqual(strength(0.6, .rising), .maintaining)
        XCTAssertEqual(strength(0.6, .unclear), .maintaining)
        XCTAssertEqual(strength(0.6, .falling), .detraining)
        XCTAssertEqual(strength(0.9, .falling), .detraining)
        XCTAssertEqual(strength(0.9, .rising), .productive)
    }

    func testADeloadAfterAHighPhaseIsRecoveringWhateverTheLiftsDo() {
        XCTAssertEqual(strength(0.6, .falling, recentHigh: true), .recovering)
        XCTAssertEqual(strength(0.6, .rising, recentHigh: true), .recovering)
    }

    /// Well above usual: recovery decides. Strained or unknown recovery is overreaching (the conventional
    /// verdict); holding recovery lets the lifts decide.
    func testWellAboveUsualAsksRecovery() {
        XCTAssertEqual(strength(1.45, .rising, recovery: .strained), .overreaching)
        XCTAssertEqual(strength(1.45, .rising, recovery: .unknown), .overreaching)
        XCTAssertEqual(strength(1.45, .rising, recovery: .holding), .productive)
        XCTAssertEqual(strength(1.45, .unclear, recovery: .holding), .unproductive)
        XCTAssertEqual(strength(1.45, .falling, recovery: .holding), .unproductive)
    }

    /// With too few lifts to judge, strength falls back to the load-only mapping — never an invented
    /// response.
    func testUnknownResponseFallsBackToLoadOnly() {
        XCTAssertEqual(strength(0.6, .unknown, daysBelow: 30), .detraining)
        XCTAssertEqual(strength(0.9, .unknown), .maintaining)
        XCTAssertEqual(strength(1.15, .unknown), .productive)
        XCTAssertEqual(strength(1.45, .unknown, recovery: .holding), .overreaching)
    }

    // MARK: - Strength response, from real workouts

    private func set(_ index: Int, kg: Double, reps: Int) -> HevySet {
        HevySet(index: index, type: .normal, weightKg: kg, reps: reps,
                distanceM: nil, durationS: nil, rpe: nil, customMetric: nil)
    }

    private var templates: [String: HevyExerciseTemplate] {
        ["BP": HevyExerciseTemplate(id: "BP", title: "Bench", type: "weight_reps", primaryMuscleGroup: .chest,
                                    secondaryMuscleGroups: [.triceps], equipment: .barbell, isCustom: false),
         "SQ": HevyExerciseTemplate(id: "SQ", title: "Squat", type: "weight_reps", primaryMuscleGroup: .quadriceps,
                                    secondaryMuscleGroups: [.glutes], equipment: .barbell, isCustom: false)]
    }

    private static func ts(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int((f.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) + 43_200
    }

    /// Two lifts trained twice a week for six weeks, each session's top set moving by `stepKg`.
    private func block(benchStart: Double, squatStart: Double, stepKg: Double,
                       endingOn last: String) -> [HevyWorkout] {
        var workouts: [HevyWorkout] = []
        for session in 0..<12 {
            let day = WeeklyDigestEngine.addDays(last, -(11 - session) * 3)
            let start = Self.ts(day)
            let exercises = [
                HevyExercise(index: 0, title: "Bench", templateId: "BP", supersetId: nil, notes: nil,
                             sets: [set(0, kg: benchStart + Double(session) * stepKg, reps: 5)]),
                HevyExercise(index: 1, title: "Squat", templateId: "SQ", supersetId: nil, notes: nil,
                             sets: [set(0, kg: squatStart + Double(session) * stepKg, reps: 5)]),
            ]
            workouts.append(HevyWorkout(id: "w\(session)", title: "Full", routineId: nil, notes: nil,
                                        startTs: start, endTs: start + 3600, updatedAtTs: start,
                                        createdAtTs: start, exercises: exercises))
        }
        return workouts
    }

    func testRisingLiftsReadAsRising() {
        let reading = TrainingStatusModel.strengthResponse(
            workouts: block(benchStart: 100, squatStart: 140, stepKg: 1.25, endingOn: "2026-09-10"),
            templates: templates, through: "2026-09-10")
        XCTAssertEqual(reading.direction, .rising)
        XCTAssertEqual(reading.rising, 2)
        XCTAssertEqual(reading.evaluated, 2)
        // Each lift is listed with its own line: 1.25 kg every three days at five reps is
        // 1.25 × (1 + 5/30) × 7/3 ≈ 3.40 kg of e1RM per week.
        XCTAssertEqual(reading.lifts.count, 2)
        XCTAssertTrue(reading.lifts.allSatisfy { $0.direction == .rising && $0.sessions == 12 })
        XCTAssertEqual(reading.lifts[0].slopePerWeekKg, 1.25 * (1 + 5.0 / 30) * 7 / 3, accuracy: 0.01)
    }

    func testFallingLiftsReadAsFalling() {
        let reading = TrainingStatusModel.strengthResponse(
            workouts: block(benchStart: 110, squatStart: 150, stepKg: -1.25, endingOn: "2026-09-10"),
            templates: templates, through: "2026-09-10")
        XCTAssertEqual(reading.direction, .falling)
    }

    /// Sessions older than the six-week window do not vote: a block that ended two months ago says
    /// nothing about the current one.
    func testSessionsOutsideTheWindowDoNotCount() {
        let old = block(benchStart: 100, squatStart: 140, stepKg: 1.25, endingOn: "2026-06-01")
        let reading = TrainingStatusModel.strengthResponse(workouts: old, templates: templates,
                                                           through: "2026-09-10")
        XCTAssertEqual(reading.evaluated, 0)
        XCTAssertEqual(reading.direction, .unknown)
    }

    /// One lift is not enough to speak for a block.
    func testASingleLiftIsNotEnough() {
        let benchOnly = block(benchStart: 100, squatStart: 140, stepKg: 1.25, endingOn: "2026-09-10").map { w in
            HevyWorkout(id: w.id, title: w.title, routineId: nil, notes: nil, startTs: w.startTs,
                        endTs: w.endTs, updatedAtTs: w.updatedAtTs, createdAtTs: w.createdAtTs,
                        exercises: [w.exercises[0]])
        }
        let reading = TrainingStatusModel.strengthResponse(workouts: benchOnly, templates: templates,
                                                           through: "2026-09-10")
        XCTAssertEqual(reading.evaluated, 1)
        XCTAssertEqual(reading.direction, .unknown)
    }

    // MARK: - VO₂max response

    private func vo2(_ values: [Double], segment: String = "nes2011", endingOn last: String = "2026-09-10") -> [VO2maxReading] {
        values.enumerated().map { index, value in
            VO2maxReading(day: WeeklyDigestEngine.addDays(last, -7 * (values.count - 1 - index)), value: value, segment: segment)
        }
    }

    /// Weekly estimates climbing steadily read as improving, with the change the line implies.
    func testRisingVO2maxIsImproving() {
        let response = TrainingStatusModel.vo2maxResponse(readings: vo2([44, 44.4, 44.9, 45.3, 45.8, 46.2]),
                                                          through: "2026-09-10")
        XCTAssertEqual(response.direction, .improving)
        XCTAssertEqual(response.readings.count, 6)
        XCTAssertEqual(response.latest?.value, 46.2)
        XCTAssertEqual(response.changeOverSpan ?? 0, 2.2, accuracy: 0.15)
        XCTAssertFalse(response.segmentBreak)
    }

    /// A switch of estimator inside the window is never read as fitness: only the latest segment counts.
    func testAnEstimatorSwitchIsNotATrend() {
        let older = vo2([40, 40, 40], segment: "uth2004", endingOn: "2026-08-20")
        let newer = vo2([46, 46.9, 47.6, 48.4], segment: "nes2011")
        let response = TrainingStatusModel.vo2maxResponse(readings: older + newer, through: "2026-09-10")
        XCTAssertTrue(response.segmentBreak)
        XCTAssertEqual(response.readings.count, 4)
        XCTAssertTrue(response.readings.allSatisfy { $0.segment == "nes2011" })
        XCTAssertEqual(response.direction, .improving)
    }

    /// An estimated VO₂max carries about a point of error, so a line that agrees on a half-point drift
    /// is describing the estimator, not the athlete. The direction is withheld until the change clears
    /// that floor — the readings still climb, and the line is still consistent.
    func testADriftSmallerThanTheEstimatorsErrorIsUnclear() {
        let response = TrainingStatusModel.vo2maxResponse(readings: vo2([45.0, 45.1, 45.2, 45.3, 45.4, 45.5]),
                                                          through: "2026-09-10")
        XCTAssertEqual(response.direction, .unclear)
        XCTAssertEqual(response.readings.count, 6)
        XCTAssertLessThan(abs(response.changeOverSpan ?? 0), TrainingStatusModel.vo2maxMinimumChange)
    }

    /// Three readings are not a line.
    func testTooFewReadingsIsUnknown() {
        let response = TrainingStatusModel.vo2maxResponse(readings: vo2([45, 45.5, 46]), through: "2026-09-10")
        XCTAssertEqual(response.direction, .unknown)
        XCTAssertNil(response.slopePerWeek)
        XCTAssertEqual(response.readings.count, 3)
    }

    // MARK: - Sustained overreaching

    private func weeks(_ strength: [TrainingStatus?], _ cardio: [TrainingStatus?]) -> [TrainingStatusModel.WeeklyStatus] {
        zip(strength, cardio).enumerated().map { index, pair in
            TrainingStatusModel.WeeklyStatus(day: "2026-08-\(String(format: "%02d", index + 1))",
                                             strength: pair.0, cardio: pair.1)
        }
    }

    private let strained = RecoveryReading(state: .strained, strainedNights: 2, nightsRead: 3, flaggingOnLatestNight: ["hrv"])
    private let holding = RecoveryReading(state: .holding, strainedNights: 0, nightsRead: 3, flaggingOnLatestNight: [])
    private let liftsFalling = StrengthResponseReading(direction: .falling, rising: 0, falling: 3, unclear: 1)
    private let liftsRising = StrengthResponseReading(direction: .rising, rising: 3, falling: 0, unclear: 1)

    /// All three together — three overreaching week-ends, falling lifts, strained recovery — raise it.
    func testLastingOverreachingWithFallingLiftsAndStrainedRecoveryWarns() {
        let history = weeks([.productive, .overreaching, .overreaching, .overreaching],
                            [.maintaining, .maintaining, .maintaining, .maintaining])
        let warning = TrainingStatusModel.sustainedOverreaching(history: history, strengthResponse: liftsFalling,
                                                                cardioDirection: .unknown, recovery: strained)
        XCTAssertEqual(warning, SustainedOverreaching(lanes: [.strength], weeks: 3))
    }

    /// Any one missing and it stays an ordinary, functional overreaching block.
    func testAnyMissingConditionKeepsItQuiet() {
        let three = weeks([.overreaching, .overreaching, .overreaching], [nil, nil, nil])
        let two = weeks([.productive, .overreaching, .overreaching], [nil, nil, nil])
        XCTAssertNil(TrainingStatusModel.sustainedOverreaching(history: two, strengthResponse: liftsFalling,
                                                               cardioDirection: .unknown, recovery: strained))
        XCTAssertNil(TrainingStatusModel.sustainedOverreaching(history: three, strengthResponse: liftsRising,
                                                               cardioDirection: .unknown, recovery: strained))
        XCTAssertNil(TrainingStatusModel.sustainedOverreaching(history: three, strengthResponse: liftsFalling,
                                                               cardioDirection: .unknown, recovery: holding))
    }

    /// The cardio lane warns on its own evidence: VO₂max falling.
    func testCardioLaneWarnsOnFallingVO2max() {
        let history = weeks([nil, nil, nil], [.overreaching, .overreaching, .overreaching])
        XCTAssertEqual(TrainingStatusModel.sustainedOverreaching(history: history, strengthResponse: liftsRising,
                                                                 cardioDirection: .worsening, recovery: strained),
                       SustainedOverreaching(lanes: [.cardio], weeks: 3))
    }

    // MARK: - Recovery, from real daily rows

    private func d(_ day: String, hrv: Double?, rhr: Int?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: 10,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    /// 28 ordinary nights, then the given final nights.
    private func nights(final: [(hrv: Double, rhr: Int)]) -> (days: [DailyMetric], last: String) {
        var rows: [DailyMetric] = []
        var cursor = "2026-08-01"
        for i in 0..<28 {
            rows.append(d(cursor, hrv: i % 2 == 0 ? 62 : 58, rhr: i % 2 == 0 ? 54 : 50))
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }
        var last = cursor
        for night in final {
            rows.append(d(cursor, hrv: night.hrv, rhr: night.rhr))
            last = cursor
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }
        return (rows, last)
    }

    /// Half a week of suppressed nights is a strained week.
    func testHalfAWeekOfSuppressedNightsIsStrained() {
        let n = nights(final: [(60, 52), (35, 64), (34, 65), (33, 66), (35, 64)])
        let reading = TrainingStatusModel.recovery(days: n.days, through: n.last)
        XCTAssertEqual(reading.state, .strained)
        XCTAssertEqual(reading.nightsRead, TrainingStatusModel.recoveryNights)
        XCTAssertGreaterThanOrEqual(reading.strainedNights,
                                    TrainingStatusModel.strainedNightsNeeded(ofNightsRead: reading.nightsRead))
        XCTAssertTrue(reading.flaggingOnLatestNight.contains("hrv"))
    }

    /// Two poor nights inside a week are a poor couple of nights. This reading gates the strength lane's
    /// top band, so it must describe the week rather than the weekend.
    func testTwoBadNightsInAWeekIsStillHolding() {
        let n = nights(final: [(60, 52), (35, 64), (34, 65)])
        let reading = TrainingStatusModel.recovery(days: n.days, through: n.last)
        XCTAssertEqual(reading.nightsRead, TrainingStatusModel.recoveryNights)
        XCTAssertEqual(reading.state, .holding)
    }

    /// One bad night is noise, not a trend.
    func testOneBadNightIsStillHolding() {
        let n = nights(final: [(60, 52), (61, 51), (34, 65)])
        XCTAssertEqual(TrainingStatusModel.recovery(days: n.days, through: n.last).state, .holding)
    }

    /// The bar scales with what was actually read, and never falls below two nights however thin the
    /// week's data is.
    func testTheStrainedBarIsProportionalWithAFloor() {
        XCTAssertEqual(TrainingStatusModel.strainedNightsNeeded(ofNightsRead: 7), 4)
        XCTAssertEqual(TrainingStatusModel.strainedNightsNeeded(ofNightsRead: 3), 2)
        XCTAssertEqual(TrainingStatusModel.strainedNightsNeeded(ofNightsRead: 2), 2)
    }

    func testNoRecentNightsIsUnknown() {
        let n = nights(final: [])
        let reading = TrainingStatusModel.recovery(days: n.days, through: "2026-10-15")
        XCTAssertEqual(reading.state, .unknown)
        XCTAssertEqual(reading.nightsRead, 0)
    }
}
