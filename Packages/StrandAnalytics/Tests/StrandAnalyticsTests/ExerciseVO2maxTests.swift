import XCTest
@testable import StrandAnalytics

/// Pins the training-based VO₂max: the published equations exactly, the sessions they may be applied to,
/// and the validation rule fixed before any real data was looked at.
final class ExerciseVO2maxTests: XCTestCase {

    private func input(day: String = "2026-09-21", km: Double = 10, minutes: Double = 60, hr: Double? = 150,
                       modality: CardioModality = .foot, measured: Bool = true,
                       resting: Double = 50, maxHR: Double = 190) -> ExerciseVO2max.SessionInput {
        ExerciseVO2max.SessionInput(day: day, startTs: 0, modality: modality, distanceM: km * 1000,
                                    durationS: minutes * 60, averageHR: hr, heartRateMeasured: measured,
                                    restingHR: resting, maxHR: maxHR)
    }

    /// The heart rate at which a wearer with `vo2max` runs `speed` m/min, by the model's own relation.
    private func heartRate(forVO2max vo2max: Double, speed: Double, gait: ExerciseVO2max.Gait,
                           resting: Double = 50, maxHR: Double = 190) -> Double {
        let vo2 = ExerciseVO2max.acsmVO2(speedMPerMin: speed, gait: gait)
        let fraction = (vo2 - ExerciseVO2max.restingVO2) / (vo2max - ExerciseVO2max.restingVO2)
        return resting + fraction * (maxHR - resting)
    }

    // MARK: - The equations, as published

    func testTheACSMEquations() {
        // Running at 10 km/h (166.67 m/min) on the flat: 0.2 × 166.67 + 3.5.
        XCTAssertEqual(ExerciseVO2max.acsmVO2(speedMPerMin: 10_000.0 / 60, gait: .running), 36.833, accuracy: 0.001)
        // Walking at 80 m/min up a 5 % grade: 0.1 × 80 + 1.8 × 80 × 0.05 + 3.5.
        XCTAssertEqual(ExerciseVO2max.acsmVO2(speedMPerMin: 80, grade: 0.05, gait: .walking), 18.7, accuracy: 1e-9)
        // Running at 200 m/min up a 2 % grade: 0.2 × 200 + 0.9 × 200 × 0.02 + 3.5.
        XCTAssertEqual(ExerciseVO2max.acsmVO2(speedMPerMin: 200, grade: 0.02, gait: .running), 47.1, accuracy: 1e-9)
    }

    /// %HRR = %VO₂R (Swain & Leutholtz 1997): half the reserve at 25 ml/kg/min above rest means 50 above.
    func testTheExtrapolation() {
        XCTAssertEqual(ExerciseVO2max.extrapolate(vo2: 28.5, fractionOfReserve: 0.5), 53.5, accuracy: 1e-9)
    }

    func testTheGaitRanges() {
        XCTAssertEqual(ExerciseVO2max.gait(speedMPerMin: 50), .walking)
        XCTAssertEqual(ExerciseVO2max.gait(speedMPerMin: 100), .walking)
        XCTAssertNil(ExerciseVO2max.gait(speedMPerMin: 120), "walking or jogging — not guessed")
        XCTAssertNil(ExerciseVO2max.gait(speedMPerMin: 134))
        XCTAssertEqual(ExerciseVO2max.gait(speedMPerMin: 135), .running)
        XCTAssertNil(ExerciseVO2max.gait(speedMPerMin: 40))
    }

    // MARK: - Recovering injected values (CLAUDE.md: several, not one)

    /// Sessions built from known VO₂max values — different speeds, gaits and wearers — must give those
    /// values back. One matched value could be a coincidence; a spread that is tracked cannot.
    func testSeveralInjectedValuesAreRecovered() {
        let cases: [(vo2max: Double, km: Double, minutes: Double, gait: ExerciseVO2max.Gait, resting: Double, maxHR: Double)] = [
            (38, 8.5, 60, .running, 60, 180),
            (45, 9.5, 60, .running, 52, 188),
            (52, 12, 60, .running, 48, 192),
            (58, 13.5, 60, .running, 45, 195),
            // Walking reaches 40 % of reserve only at a low VO₂max: for a fit wearer a walk is too easy
            // to extrapolate from, and is left out by the intensity gate rather than read high.
            (26, 6, 60, .walking, 62, 175),
        ]
        for c in cases {
            let speed = c.km * 1000 / c.minutes
            let hr = heartRate(forVO2max: c.vo2max, speed: speed, gait: c.gait, resting: c.resting, maxHR: c.maxHR)
            guard case let .estimate(estimate) = ExerciseVO2max.estimate(
                input(km: c.km, minutes: c.minutes, hr: hr, resting: c.resting, maxHR: c.maxHR)) else {
                return XCTFail("\(c) was excluded")
            }
            XCTAssertEqual(estimate.gait, c.gait)
            XCTAssertEqual(estimate.vo2max, c.vo2max, accuracy: 1e-6, "\(c)")
        }
    }

    // MARK: - What is left out

    func testTheExclusions() {
        func outcome(_ i: ExerciseVO2max.SessionInput) -> ExerciseVO2max.Exclusion? {
            if case let .excluded(reason) = ExerciseVO2max.estimate(i) { return reason }
            return nil
        }
        XCTAssertEqual(outcome(input(modality: .cycling)), .notOnFoot)
        XCTAssertEqual(outcome(input(km: 0)), .noDistance)
        XCTAssertEqual(outcome(input(minutes: 15)), .tooShort)
        XCTAssertEqual(outcome(input(km: 7, minutes: 60)), .speedBetweenGaits)
        XCTAssertEqual(outcome(input(km: 2, minutes: 60)), .speedOutOfRange)
        XCTAssertEqual(outcome(input(measured: false)), .heartRateNotMeasured, "an average-only estimate is not a trace")
        XCTAssertEqual(outcome(input(hr: nil)), .heartRateNotMeasured)
        XCTAssertEqual(outcome(input(hr: 90)), .intensityOutOfRange, "29 % of reserve")
        XCTAssertEqual(outcome(input(hr: 180)), .intensityOutOfRange, "93 % of reserve")
        XCTAssertEqual(outcome(input(resting: 60, maxHR: 55)), .invalidHeartRateBounds)
    }

    // MARK: - Weeks

    func testAWeekIsTheMedianOfItsSessions() {
        let days = ["2026-09-21", "2026-09-23", "2026-09-25", "2026-09-29"]  // Mon, Wed, Fri, next Tue
        let hrs: [Double] = [150, 145, 155, 150]
        let estimates = zip(days, hrs).compactMap { day, hr -> ExerciseVO2max.SessionEstimate? in
            if case let .estimate(e) = ExerciseVO2max.estimate(input(day: day, hr: hr)) { return e }
            return nil
        }
        let weeks = ExerciseVO2max.weekly(estimates)
        XCTAssertEqual(weeks.map(\.mondayKey), ["2026-09-21", "2026-09-28"])
        XCTAssertEqual(weeks.map(\.sessions), [3, 1])
        XCTAssertEqual(weeks[0].lastDay, "2026-09-25")
        XCTAssertEqual(weeks[0].value, estimates[0].vo2max, accuracy: 1e-9, "the median of three is the middle one")
    }

    // MARK: - Validation

    private func week(_ monday: String, _ value: Double) -> ExerciseVO2max.WeeklyEstimate {
        ExerciseVO2max.WeeklyEstimate(mondayKey: monday, lastDay: WeeklyDigestEngine.addDays(monday, 4),
                                      value: value, sessions: 2)
    }

    private func series(_ values: [Double], offset: Double = 0, noise: [Double]? = nil)
    -> (weekly: [ExerciseVO2max.WeeklyEstimate], apple: [VO2maxReading]) {
        var weekly: [ExerciseVO2max.WeeklyEstimate] = []
        var apple: [VO2maxReading] = []
        for (index, value) in values.enumerated() {
            let monday = WeeklyDigestEngine.addDays("2026-06-01", index * 7)
            weekly.append(week(monday, value + offset + (noise?[index] ?? 0)))
            apple.append(VO2maxReading(day: WeeklyDigestEngine.addDays(monday, 3), value: value, segment: "apple-health"))
        }
        return (weekly, apple)
    }

    func testAnInstrumentThatTracksAppleWithinTheErrorPasses() {
        let s = series([40, 41, 42, 41.5, 43, 44, 43, 45, 46], offset: 1.5)
        let report = ExerciseVO2max.validate(weekly: s.weekly, apple: s.apple)
        XCTAssertEqual(report.pairs, 9)
        XCTAssertEqual(report.meanAbsoluteError ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(report.directionAgreement ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(report.passes)
    }

    /// A close level that does not move with Apple is a coincidence, not an instrument.
    func testAMatchingLevelThatDoesNotTrackFails() {
        let apple = [40.0, 42, 40, 42, 40, 42, 40, 42, 40]
        let flat = apple.map { _ in 41.0 }
        var weekly: [ExerciseVO2max.WeeklyEstimate] = []
        var readings: [VO2maxReading] = []
        for index in apple.indices {
            let monday = WeeklyDigestEngine.addDays("2026-06-01", index * 7)
            weekly.append(week(monday, flat[index]))
            readings.append(VO2maxReading(day: WeeklyDigestEngine.addDays(monday, 3), value: apple[index], segment: "apple-health"))
        }
        let report = ExerciseVO2max.validate(weekly: weekly, apple: readings)
        XCTAssertLessThanOrEqual(report.meanAbsoluteError ?? 99, 1)
        XCTAssertFalse(report.passes)
    }

    func testTooLargeAnErrorFails() {
        let s = series([40, 41, 42, 43, 44, 45, 46, 47, 48], offset: 5)
        XCTAssertFalse(ExerciseVO2max.validate(weekly: s.weekly, apple: s.apple).passes)
    }

    /// With the watch rarely worn there are too few pairs to judge, and the instrument stays experimental.
    func testTooFewPairsIsNoVerdict() {
        let s = series([40, 41, 42, 43, 44], offset: 0.5)
        let report = ExerciseVO2max.validate(weekly: s.weekly, apple: s.apple)
        XCTAssertEqual(report.pairs, 5)
        XCTAssertFalse(report.passes)
    }

    func testReadingsTooFarApartDoNotPair() {
        let report = ExerciseVO2max.validate(
            weekly: [week("2026-06-01", 45)],
            apple: [VO2maxReading(day: "2026-06-20", value: 45, segment: "apple-health")])
        XCTAssertEqual(report.pairs, 0)
    }
}
