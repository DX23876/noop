import XCTest
@testable import StrandAnalytics

final class ScaleBurnTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func day(_ offset: Int) -> String {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let date = calendar.date(byAdding: .day, value: offset, to: start)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Eight weeks of logged days and twice-weekly weigh-ins losing 0.5 kg a week, with a little water noise.
    private func history(eaten: Double = 3_000, lossPerWeek: Double = 0.5, logged: Int = 56, noise: Double = 0.3)
        -> (intake: [String: Double], weighIns: [(day: String, kg: Double)], strap: [String: Double]) {
        var intake: [String: Double] = [:]
        var strap: [String: Double] = [:]
        for d in 0..<logged { intake[day(d)] = eaten + Double((d * 37) % 200 - 100); strap[day(d)] = 3_400 }
        let weighIns = stride(from: 0, to: 56, by: 3).map { d -> (day: String, kg: Double) in
            // Irregular water swings: a fixed pseudo-random pattern, so the test is the same on every run.
            (day(d), 200 - lossPerWeek * Double(d) / 7 + noise * sin(Double(d) * 2.399) * (d % 5 == 0 ? 1.8 : 1))
        }
        return (intake, weighIns, strap)
    }

    func testEightWeeksRecoverTheBurnTheWeightImplies() throws {
        let h = history()
        let outcome = ScaleBurn.estimate(completeIntake: h.intake, weighIns: h.weighIns, strapByDay: h.strap,
                                         today: day(57), kcalPerKg: 8_700, calendar: calendar)
        guard case .estimate(let e) = outcome else { return XCTFail("no estimate: \(outcome)") }
        let expected = 3_000 + 0.5 / 7 * 8_700
        XCTAssertEqual(e.burnKcal, expected, accuracy: expected * 0.03)
        XCTAssertEqual(try XCTUnwrap(e.ratio), e.burnKcal / 3_400, accuracy: 1e-9)
        XCTAssertLessThan(e.relativeError, ScaleBurn.maximumRelativeError)
    }

    /// The same weight loss means less burn for a lean body, whose kilogram holds less energy.
    func testTheEnergyInAKilogramMovesTheBurn() throws {
        let h = history()
        func burn(_ density: Double) -> Double? {
            guard case .estimate(let e) = ScaleBurn.estimate(completeIntake: h.intake, weighIns: h.weighIns,
                                                             strapByDay: h.strap, today: day(57),
                                                             kcalPerKg: density, calendar: calendar) else { return nil }
            return e.burnKcal
        }
        XCTAssertGreaterThan(try XCTUnwrap(burn(8_700)), try XCTUnwrap(burn(5_100)))
    }

    func testFourWeeksAreNotEnough() {
        let h = history()
        let short = h.weighIns.filter { $0.day >= day(28) }
        let outcome = ScaleBurn.estimate(completeIntake: h.intake.filter { $0.key >= day(28) }, weighIns: short,
                                         strapByDay: h.strap, today: day(57), kcalPerKg: 8_700, calendar: calendar)
        guard case .missing(let days, _, _, _, let uncertain) = outcome else { return XCTFail("estimated too early") }
        XCTAssertLessThan(days, ScaleBurn.minimumCompleteDays + 10)
        XCTAssertFalse(uncertain)
    }

    /// Three to four weeks are not enough for a figure, but enough for the early look's direction, which needs
    /// its own looser gate and is never what a proposal reads.
    func testFourWeeksGiveAnEarlyLookButNoFigure() throws {
        let h = history()
        let intake = h.intake.filter { $0.key >= day(28) }
        let weighIns = h.weighIns.filter { $0.day >= day(28) }
        guard case .missing = ScaleBurn.estimate(completeIntake: intake, weighIns: weighIns, strapByDay: h.strap,
                                                 today: day(57), kcalPerKg: 8_700, calendar: calendar) else {
            return XCTFail("a figure after four weeks")
        }
        guard case .estimate(let early) = ScaleBurn.estimate(completeIntake: intake, weighIns: weighIns,
                                                             strapByDay: h.strap, today: day(57), kcalPerKg: 8_700,
                                                             gates: .early, calendar: calendar) else {
            return XCTFail("no early look after four weeks")
        }
        let expected = 3_000 + 0.5 / 7 * 8_700
        XCTAssertEqual(early.burnKcal, expected, accuracy: expected * 0.06)
        XCTAssertGreaterThan(try XCTUnwrap(early.ratio), 1, "about 3,620 against a strap at 3,400")
        // Two weeks hold too little even for a look.
        guard case .missing = ScaleBurn.estimate(completeIntake: h.intake.filter { $0.key >= day(43) },
                                                 weighIns: h.weighIns.filter { $0.day >= day(43) }, strapByDay: h.strap,
                                                 today: day(57), kcalPerKg: 8_700, gates: .early,
                                                 calendar: calendar) else {
            return XCTFail("an early look after two weeks")
        }
    }

    /// Water swings widen the figure's uncertainty; past 10 % of the burn it is not offered at all.
    func testWaterSwingsWidenTheUncertaintyUntilItIsNotOffered() throws {
        func outcome(_ noise: Double) -> ScaleBurn.Outcome {
            let h = history(noise: noise)
            return ScaleBurn.estimate(completeIntake: h.intake, weighIns: h.weighIns, strapByDay: h.strap,
                                      today: day(57), kcalPerKg: 8_700, calendar: calendar)
        }
        guard case .estimate(let calm) = outcome(0.2), case .estimate(let rough) = outcome(1.0) else {
            return XCTFail("expected two figures")
        }
        XCTAssertGreaterThan(rough.errorKcal, calm.errorKcal)
        guard case .missing(_, _, _, _, let uncertain) = outcome(6) else { return XCTFail("offered a wild figure") }
        XCTAssertTrue(uncertain)
    }
}

final class BurnCorrectionTests: XCTestCase {
    func testAProposalNeedsAGapAndNoDisturbance() {
        let none = BurnCorrection()
        XCTAssertEqual(none.evaluated(target: 1.02, today: "2026-12-01", holding: false, measured: false).status, .none)
        XCTAssertEqual(none.evaluated(target: 1.08, today: "2026-12-01", holding: true, measured: false).status, .none)
        let proposed = none.evaluated(target: 1.08, today: "2026-12-01", holding: false, measured: false)
        XCTAssertEqual(proposed.status, .proposed)
        XCTAssertEqual(proposed.targetFactor, 1.08)
    }

    func testAcceptedItMovesAtMostThreePercentAWeekAndNeverPastTwenty() throws {
        var c = BurnCorrection().evaluated(target: 1.35, today: "2026-12-01", holding: false, measured: false)
        c = c.accepted(today: "2026-12-01")
        XCTAssertEqual(c.factor, 1.2, "capped at +20 %")
        c = c.evaluated(target: 1.0, today: "2026-12-04", holding: false, measured: false)
        XCTAssertEqual(c.factor, 1.2, "not a week yet")
        c = c.evaluated(target: 1.0, today: "2026-12-08", holding: false, measured: false)
        XCTAssertEqual(c.factor, 1.17, accuracy: 1e-9)
        c = c.evaluated(target: 1.0, today: "2026-12-15", holding: true, measured: false)
        XCTAssertEqual(c.factor, 1.17, accuracy: 1e-9, "held while a disturbance settles")
        XCTAssertNil(c.factor(on: "2026-11-30"), "never before the day of agreement")
        XCTAssertEqual(try XCTUnwrap(c.factor(on: "2026-12-15")), 1.17, accuracy: 1e-9)
        XCTAssertNil(c.turnedOff().factor(on: "2026-12-15"))
    }

    func testADeclinedProposalReturnsAfterEightWeeks() {
        let declined = BurnCorrection().evaluated(target: 1.1, today: "2026-12-01", holding: false, measured: false)
            .declined(today: "2026-12-01")
        XCTAssertEqual(declined.evaluated(target: 1.1, today: "2027-01-10", holding: false, measured: false).status, .declined)
        XCTAssertEqual(declined.evaluated(target: 1.1, today: "2027-01-27", holding: false, measured: false).status, .proposed)
    }

    /// With a measured resting rate basal stays, so everything else moves more for the same day total.
    func testTheTargetLeavesAMeasuredBasalAlone() {
        XCTAssertEqual(BurnCorrection.target(ratio: 1.1, basalShare: nil), 1.1, accuracy: 1e-9)
        XCTAssertEqual(BurnCorrection.target(ratio: 1.1, basalShare: 0.6), 1.25, accuracy: 1e-9)
        XCTAssertEqual(BurnCorrection.target(ratio: 1.5, basalShare: nil), 1.2, accuracy: 1e-9)
    }
}

final class EnergyDensityTests: XCTestCase {
    /// A body with much fat loses mostly fat; a lean one loses more fat-free mass, which holds far less.
    func testTheKilogramFollowsTheBodysFat() throws {
        let heavy = try XCTUnwrap(EnergyDensity.kcalPerKg(weightKg: 200, bodyFatPercent: 51))
        let lean = try XCTUnwrap(EnergyDensity.kcalPerKg(weightKg: 60, bodyFatPercent: 13))
        XCTAssertEqual(heavy, 8_730, accuracy: 30)
        XCTAssertEqual(lean, 5_070, accuracy: 60)
        XCTAssertGreaterThan(heavy, 7_700)
        XCTAssertLessThan(lean, 7_700)
    }

    func testCunBaeAndItsOrder() throws {
        let owner = try XCTUnwrap(BodyFatEstimate.cunBae(bmi: 52.1, age: 35, female: false))
        XCTAssertEqual(owner, 50.8, accuracy: 0.3)
        XCTAssertEqual(BodyFatEstimate.resolve(measured: 40, tape: 45, weightKg: 200, heightCm: 196, age: 35,
                                               female: false), 40)
        XCTAssertEqual(BodyFatEstimate.resolve(measured: nil, tape: 45, weightKg: 200, heightCm: 196, age: 35,
                                               female: false), 45)
        XCTAssertEqual(try XCTUnwrap(BodyFatEstimate.resolve(measured: nil, tape: nil, weightKg: 200, heightCm: 196,
                                                             age: 35, female: false)), owner, accuracy: 0.5)
    }
}
