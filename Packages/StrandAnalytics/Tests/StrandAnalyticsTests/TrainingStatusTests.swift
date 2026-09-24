import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins what the Training Load verdicts read: the lifts' response, the VO₂max line, recovery and the
/// lasting-overload warning. The band and the verdict table themselves are pinned in `LaneEngineTests`.
final class TrainingStatusTests: XCTestCase {
    func testMissingPerformanceEvidenceNeverClaimsAdaptation() {
        let strength = TrainingStatusModel.strengthAdaptation(
            StrengthResponseReading(direction: .unknown, rising: 0, falling: 0, unclear: 0))
        let cardio = TrainingStatusModel.cardiovascularAdaptation(
            CardioEvidenceReading(evidence: .none, source: .none, apple: nil, efficiency: nil))
        XCTAssertEqual(strength.state, .notEnoughData)
        XCTAssertEqual(cardio.state, .notEnoughData)
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

    private func weeks(_ strength: [RelativeLoadBand?], _ cardio: [RelativeLoadBand?])
    -> [TrainingStatusModel.WeeklyLoadBands] {
        zip(strength, cardio).enumerated().map { index, pair in
            TrainingStatusModel.WeeklyLoadBands(day: "2026-08-\(String(format: "%02d", index + 1))",
                                                strength: pair.0, cardio: pair.1)
        }
    }

    private let strained = RecoveryReading(state: .strained, strainedNights: 2, nightsRead: 3, flaggingOnLatestNight: ["hrv"])
    private let holding = RecoveryReading(state: .holding, strainedNights: 0, nightsRead: 3, flaggingOnLatestNight: [])

    /// All three together — three week-ends well above usual, falling lifts, strained recovery — raise it.
    func testLastingOverloadWithFallingLiftsAndStrainedRecoveryWarns() {
        let history = weeks([.higher, .muchHigher, .muchHigher, .muchHigher],
                            [.usual, .usual, .usual, .usual])
        let warning = TrainingStatusModel.sustainedOverreaching(history: history, strengthEvidence: .falling,
                                                                cardioEvidence: .none, recovery: strained)
        XCTAssertEqual(warning, SustainedOverreaching(lanes: [.strength], weeks: 3))
    }

    /// Any one missing and it stays an ordinary, functional block.
    func testAnyMissingConditionKeepsItQuiet() {
        let three = weeks([.muchHigher, .muchHigher, .muchHigher], [nil, nil, nil])
        let two = weeks([.higher, .muchHigher, .muchHigher], [nil, nil, nil])
        XCTAssertNil(TrainingStatusModel.sustainedOverreaching(history: two, strengthEvidence: .falling,
                                                               cardioEvidence: .none, recovery: strained))
        XCTAssertNil(TrainingStatusModel.sustainedOverreaching(history: three, strengthEvidence: .rising,
                                                               cardioEvidence: .none, recovery: strained))
        XCTAssertNil(TrainingStatusModel.sustainedOverreaching(history: three, strengthEvidence: .none,
                                                               cardioEvidence: .none, recovery: strained))
        XCTAssertNil(TrainingStatusModel.sustainedOverreaching(history: three, strengthEvidence: .falling,
                                                               cardioEvidence: .none, recovery: holding))
    }

    /// The cardio lane warns on its own evidence.
    func testCardioLaneWarnsOnItsOwnFallingEvidence() {
        let history = weeks([nil, nil, nil], [.muchHigher, .muchHigher, .muchHigher])
        XCTAssertEqual(TrainingStatusModel.sustainedOverreaching(history: history, strengthEvidence: .rising,
                                                                 cardioEvidence: .falling, recovery: strained),
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
