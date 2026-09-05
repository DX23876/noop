import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the strength-versus-recovery analysis.
///
/// One test here matters more than the rest: **the control group must be other TRAINING days.** With
/// rest days as the control, the comparison measures training against not training and hands the whole
/// cost of having gone to the gym to whichever muscle group was trained — a "−13 Charge after leg day"
/// that is mostly "you trained". It is the kind of wrong answer that looks completely reasonable, which
/// is why it gets its own test rather than a comment.
final class StrengthRecoveryResponseTests: XCTestCase {

    // MARK: - Fixtures

    private func templates() -> [String: HevyExerciseTemplate] {
        [
            "SQUAT": template("SQUAT", .quadriceps),
            "CURL": template("CURL", .hamstrings),
            "BENCH": template("BENCH", .chest),
            "ROW": template("ROW", .lats),
        ]
    }

    private func template(_ id: String, _ primary: HevyMuscleGroup) -> HevyExerciseTemplate {
        HevyExerciseTemplate(id: id, title: id, type: "weight_reps", primaryMuscleGroup: primary,
                             secondaryMuscleGroups: [], equipment: .barbell, isCustom: false)
    }

    private func session(_ day: String, _ exercises: [(String, Int)]) -> HevyWorkout {
        let ts = Self.timestamp(day)
        return HevyWorkout(
            id: "\(day)-\(exercises.map(\.0).joined())", title: "", routineId: nil, notes: nil,
            startTs: ts, endTs: ts + 3600, updatedAtTs: ts, createdAtTs: ts,
            exercises: exercises.enumerated().map { index, entry in
                HevyExercise(index: index, title: entry.0, templateId: entry.0,
                             supersetId: nil, notes: nil,
                             sets: (0..<entry.1).map {
                                 HevySet(index: $0, type: .normal, weightKg: 100, reps: 5,
                                         distanceM: nil, durationS: nil, rpe: nil, customMetric: nil)
                             })
            })
    }

    /// Noon UTC on a "yyyy-MM-dd" day, so the session lands unambiguously on that day key.
    private static func timestamp(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int((f.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) + 43_200
    }

    private func day(_ index: Int) -> String { String(format: "2026-06-%02d", index) }

    // MARK: - Classification

    func testASessionOfMostlyLegWorkIsALegDay() {
        let w = session(day(1), [("SQUAT", 8), ("CURL", 4), ("BENCH", 2)])
        XCTAssertEqual(StrengthRecoveryResponse.classify(w, templates: templates()), .legs)
    }

    func testASessionOfMostlyUpperWorkIsAnUpperDay() {
        let w = session(day(1), [("BENCH", 8), ("ROW", 6), ("SQUAT", 2)])
        XCTAssertEqual(StrengthRecoveryResponse.classify(w, templates: templates()), .upper)
    }

    /// A genuinely mixed day belongs to neither. Attributing a full-body session to legs is how a
    /// category quietly stops meaning what its label says.
    func testAnEvenlySplitSessionIsMixed() {
        let w = session(day(1), [("SQUAT", 6), ("BENCH", 6)])
        XCTAssertEqual(StrengthRecoveryResponse.classify(w, templates: templates()), .mixed)
    }

    /// An exercise the catalogue does not know contributes no muscle, so a session made only of such
    /// exercises is unclassifiable rather than assigned by guesswork.
    func testASessionOfUnknownExercisesIsMixed() {
        let w = session(day(1), [("NOT-IN-CATALOGUE", 10)])
        XCTAssertEqual(StrengthRecoveryResponse.classify(w, templates: templates()), .mixed)
    }

    // MARK: - THE control-group test

    /// Legs on one set of days, rest on all the others, and a Charge series that is simply lower after
    /// any training day. There are no other TRAINING days, so there is no honest comparison to make and
    /// the analysis must report that it cannot answer — not a large, significant-looking effect.
    ///
    /// A control of "every non-leg day" would sail through this and report the entire cost of training
    /// as the cost of legs.
    func testLegDaysAgainstOnlyRestDaysProduceNoAnswer() {
        var workouts: [HevyWorkout] = []
        var charge: [String: Double] = [:]
        for i in 1...28 {
            let d = day(i)
            let trained = i % 3 == 0
            if trained { workouts.append(session(d, [("SQUAT", 10)])) }
            // Every morning after a session reads 20 lower — a huge, perfectly consistent "effect".
            let previousTrained = (i - 1) % 3 == 0 && i > 1
            charge[d] = previousTrained ? 50 : 70
        }
        let response = StrengthRecoveryResponse.response(
            kind: .legs, outcome: "Charge", workouts: workouts, templates: templates(),
            outcomeByDay: charge)

        XCTAssertEqual(response.controlCount, 0, "rest days are not controls")
        XCTAssertFalse(response.isReady,
                       "with no other training days there is nothing to compare legs against")
        XCTAssertGreaterThan(response.missingControls, 0)
    }

    /// The same shape, but now with upper days as the control and legs genuinely costing more. THIS is
    /// the comparison the card claims to make, and it does produce an answer.
    ///
    /// The schedule deliberately leaves a rest day between every session. My first attempt at this
    /// fixture ran leg/upper on consecutive days, which made "the day after a leg day" and "an upper
    /// day" the SAME day — the two lags were perfectly confounded, and the ranker rightly reported the
    /// same-day effect as the stronger one. A test whose data cannot separate the thing being measured
    /// proves nothing about the code.
    func testLegDaysAgainstUpperDaysDoProduceAnAnswer() throws {
        var workouts: [HevyWorkout] = []
        var legDays: Set<String> = []
        var upperDays: Set<String> = []

        // Period of four: leg, rest, upper, rest. No two sessions are adjacent, so a session day is
        // never also the morning after another session.
        var cursor = "2026-06-01"
        for index in 0..<80 {
            switch index % 4 {
            case 0:
                workouts.append(session(cursor, [("SQUAT", 10)]))
                legDays.insert(cursor)
            case 2:
                workouts.append(session(cursor, [("BENCH", 10)]))
                upperDays.insert(cursor)
            default:
                break
            }
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }

        // Only the MORNING AFTER carries the effect; the session day itself reads neutral. Legs cost
        // 15, upper costs 5, so the honest comparison is a 10-point difference at lag 1.
        //
        // The ±1 wobble is not decoration. Without it every value inside a group is identical, the
        // pooled standard deviation is zero, and Cohen's d — a difference DIVIDED by that SD — is
        // undefined. My first fixture had exactly that, and the ranker then picked a lag whose effect
        // was literally zero. Real measurements always vary; a fixture that does not cannot exercise a
        // test built on variance.
        var charge: [String: Double] = [:]
        var day = "2026-06-01"
        for index in 0..<82 {
            let wobble = Double((index % 3) - 1)          // −1, 0, +1, repeating
            let previous = WeeklyDigestEngine.addDays(day, -1)
            if legDays.contains(previous) { charge[day] = 55 + wobble }
            else if upperDays.contains(previous) { charge[day] = 65 + wobble }
            else { charge[day] = 70 + wobble }
            day = WeeklyDigestEngine.addDays(day, 1)
        }

        let legs = StrengthRecoveryResponse.response(
            kind: .legs, outcome: "Charge", workouts: workouts, templates: templates(),
            outcomeByDay: charge)
        XCTAssertGreaterThanOrEqual(legs.controlCount, 5, "upper days are the control group")
        let effect = try XCTUnwrap(legs.effect, "both groups cleared the gate, so there is an answer")
        XCTAssertEqual(effect.lag, 1, "the cost shows up the next morning")
        // Around −10 — legs cost 15, upper costs 5, and what the comparison reports is the EXTRA. The
        // tolerance is the fixture's own ±1 wobble, not slack in the arithmetic.
        XCTAssertEqual(effect.effect.delta, -10, accuracy: 1.5,
                       "legs cost 15, upper costs 5 — the difference between them is what legs cost EXTRA")
    }

    // MARK: - The gate

    /// Below the group threshold the response says HOW MANY more sessions are needed, and carries no
    /// number. A placeholder figure on a health card is the confusion that must not happen.
    func testTooFewSessionsReportAShortfallAndNoNumber() {
        let workouts = [
            session(day(1), [("SQUAT", 10)]),
            session(day(3), [("BENCH", 10)]),
        ]
        let response = StrengthRecoveryResponse.response(
            kind: .legs, outcome: "Charge", workouts: workouts, templates: templates(),
            outcomeByDay: [day(2): 60, day(4): 70])

        XCTAssertNil(response.effect)
        XCTAssertFalse(response.isReady)
        XCTAssertEqual(response.sessionCount, 1)
        XCTAssertEqual(response.missingSessions,
                       BehaviorInsights.minGroupForSignificance - 1)
    }

    // MARK: - The comparison sentence

    /// It needs both sides measured, both pointing the same way, and a real gap. Anything less and it
    /// stays silent rather than calling a rounding difference a finding.
    func testTheComparisonNeedsBothSidesAndARealGap() {
        func response(_ kind: StrengthSessionKind, delta: Double) -> StrengthRecoveryResponse.Response {
            let effect = BehaviorEffect(behavior: kind.label, outcome: "Charge",
                                        meanWith: 60 + delta, meanWithout: 60, delta: delta,
                                        pctChange: delta, nWith: 8, nWithout: 8,
                                        cohensD: delta / 5, pApprox: 0.01, significant: true)
            return .init(kind: kind, outcome: "Charge",
                         effect: RankedEffect(behavior: kind.label, outcome: "Charge", lag: 1,
                                              effect: effect, confidence: .solid),
                         sessionCount: 8, controlCount: 8, neededPerGroup: 5)
        }
        let bigGap = StrengthRecoveryResponse.comparison(legs: response(.legs, delta: -13),
                                                         upper: response(.upper, delta: -6))
        XCTAssertNotNil(bigGap)
        XCTAssertTrue(try XCTUnwrap(bigGap).contains("Legs"), bigGap ?? "")

        let tinyGap = StrengthRecoveryResponse.comparison(legs: response(.legs, delta: -7),
                                                          upper: response(.upper, delta: -6))
        XCTAssertNil(tinyGap, "one point apart is not a finding")

        let oneSideMissing = StrengthRecoveryResponse.comparison(
            legs: response(.legs, delta: -13),
            upper: .init(kind: .upper, outcome: "Charge", effect: nil,
                         sessionCount: 2, controlCount: 8, neededPerGroup: 5))
        XCTAssertNil(oneSideMissing, "a comparison needs two measured sides")
    }

    /// It never claims causation. These are paired observations and the user chose which day to train.
    func testTheComparisonSaysGoesWithNotCauses() throws {
        func response(_ kind: StrengthSessionKind, delta: Double) -> StrengthRecoveryResponse.Response {
            let effect = BehaviorEffect(behavior: kind.label, outcome: "Charge",
                                        meanWith: 60 + delta, meanWithout: 60, delta: delta,
                                        pctChange: delta, nWith: 8, nWithout: 8,
                                        cohensD: delta / 5, pApprox: 0.01, significant: true)
            return .init(kind: kind, outcome: "Charge",
                         effect: RankedEffect(behavior: kind.label, outcome: "Charge", lag: 1,
                                              effect: effect, confidence: .solid),
                         sessionCount: 8, controlCount: 8, neededPerGroup: 5)
        }
        let text = try XCTUnwrap(StrengthRecoveryResponse.comparison(
            legs: response(.legs, delta: -13), upper: response(.upper, delta: -6)))
        XCTAssertTrue(text.contains("go with"), text)
        XCTAssertFalse(text.lowercased().contains("caus"), text)
    }
}
