import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HealthspanEngineTests: XCTestCase {

    private typealias E = HealthspanEngine

    /// Someone who meets every recommendation exactly reads at their own age, every component at 0.
    func testReferentReadsAtOwnAge() {
        let r = E.compute(.init(age: 30, sex: .male, sleepHours: 7, sleepConsistencyPct: 70,
                                dailySteps: 8000, zone13MinPerWeek: 100, zone45MinPerWeek: 10,
                                strengthMinPerWeek: 40, vo2max: 44, restingHR: 60, leanMassPct: 80))!
        XCTAssertEqual(r.healthspanAge, 30, accuracy: 1e-9)
        XCTAssertEqual(r.contributions.count, E.Component.allCases.count)
        for c in r.contributions { XCTAssertEqual(c.years, 0, accuracy: 1e-9, "\(c.component)") }
    }

    /// The four published reference profiles (30-year-olds). Ranges use their midpoint;
    /// the unknown US Zone 4-5 time is 0. `overlapFactor` is fitted on these same four profiles, so this guards
    /// against regressions in the curves; it is not an independent validation.
    func testReferenceProfileAnchors() {
        let usMale = E.compute(.init(age: 30, sex: .male, sleepHours: 6.35, sleepConsistencyPct: 65,
                                     dailySteps: 5200, zone13MinPerWeek: 69, zone45MinPerWeek: 0,
                                     strengthMinPerWeek: 0, vo2max: 42.4, restingHR: 67, leanMassPct: 73.9))!
        let activeMale = E.compute(.init(age: 30, sex: .male, sleepHours: 7.0, sleepConsistencyPct: 67,
                                        dailySteps: 10900, zone13MinPerWeek: 141, zone45MinPerWeek: 6,
                                        strengthMinPerWeek: 46, vo2max: 46.8, restingHR: 58, leanMassPct: 81))!
        let usFemale = E.compute(.init(age: 30, sex: .female, sleepHours: 6.35, sleepConsistencyPct: 65,
                                       dailySteps: 5000, zone13MinPerWeek: 46, zone45MinPerWeek: 0,
                                       strengthMinPerWeek: 0, vo2max: 30.2, restingHR: 72, leanMassPct: 62.2))!
        let activeFemale = E.compute(.init(age: 30, sex: .female, sleepHours: 7.3, sleepConsistencyPct: 68,
                                          dailySteps: 11500, zone13MinPerWeek: 124, zone45MinPerWeek: 7,
                                          strengthMinPerWeek: 56, vo2max: 40, restingHR: 63, leanMassPct: 73))!
        XCTAssertEqual(usMale.deltaYears, 6.0, accuracy: 0.5)
        XCTAssertEqual(activeMale.deltaYears, -1.6, accuracy: 0.5)
        XCTAssertEqual(usFemale.deltaYears, 7.5, accuracy: 0.5)
        XCTAssertEqual(activeFemale.deltaYears, -1.6, accuracy: 0.5)
    }

    /// Improving any single component never makes the age older, and a clear improvement makes it younger.
    func testEachComponentMovesTheRightWay() {
        let base = E.Inputs(age: 40, sex: .female, sleepHours: 6, sleepConsistencyPct: 60, dailySteps: 4000,
                            zone13MinPerWeek: 30, zone45MinPerWeek: 0, strengthMinPerWeek: 0, vo2max: 28,
                            restingHR: 72, leanMassPct: 60)
        let baseAge = E.compute(base)!.healthspanAge
        let better: [(String, (inout E.Inputs) -> Void)] = [
            ("sleep", { $0.sleepHours = 7.5 }), ("consistency", { $0.sleepConsistencyPct = 85 }),
            ("steps", { $0.dailySteps = 9000 }), ("z13", { $0.zone13MinPerWeek = 200 }),
            ("z45", { $0.zone45MinPerWeek = 30 }), ("strength", { $0.strengthMinPerWeek = 60 }),
            ("vo2", { $0.vo2max = 38 }), ("rhr", { $0.restingHR = 58 }), ("lbm", { $0.leanMassPct = 70 }),
        ]
        for (name, apply) in better {
            var x = base; apply(&x)
            XCTAssertLessThan(E.compute(x)!.healthspanAge, baseAge - 0.05, name)
        }
    }

    /// A missing component contributes nothing and is flagged; with no component at all there is no age.
    func testMissingComponents() {
        let r = E.compute(.init(age: 35, sex: .male, restingHR: 70))!
        XCTAssertEqual(r.componentsUsed, 1)
        let lbm = r.contributions.first { $0.component == .leanMass }!
        XCTAssertNil(lbm.value)
        XCTAssertEqual(lbm.years, 0)
        XCTAssertNil(E.compute(.init(age: 35, sex: .male)))
        XCTAssertNil(E.compute(.init(age: 0, sex: .male, restingHR: 60)))
    }

    /// No extrapolation beyond the studied range: 20 000 steps counts like the top quartile median.
    func testCurvesHoldAtTheirEnds() {
        let a = E.compute(.init(age: 30, sex: .male, dailySteps: 10901))!.healthspanAge
        let b = E.compute(.init(age: 30, sex: .male, dailySteps: 20000))!.healthspanAge
        XCTAssertEqual(a, b, accuracy: 1e-9)
        // Over 9 h of sleep has no effect, by the method's rule.
        XCTAssertEqual(E.compute(.init(age: 30, sex: .male, sleepHours: 10))!.deltaYears, 0, accuracy: 1e-9)
    }

    /// Age- and sex-dependent targets follow the published tables.
    func testTargets() {
        XCTAssertEqual(E.vo2maxTarget(age: 30, sex: .male), 44)
        XCTAssertEqual(E.vo2maxTarget(age: 32.5, sex: .male), 43, accuracy: 1e-9)
        XCTAssertEqual(E.vo2maxTarget(age: 18, sex: .female), 40)
        XCTAssertEqual(E.vo2maxTarget(age: 110, sex: .female), 18)
        XCTAssertEqual(E.target(.dailySteps, age: 45, sex: .male), 8000)
        XCTAssertEqual(E.target(.dailySteps, age: 60, sex: .male), 6800, accuracy: 1e-9)
        XCTAssertEqual(E.target(.dailySteps, age: 75, sex: .male), 5600)
        XCTAssertEqual(E.target(.zone13, age: 70, sex: .female), 70)
        XCTAssertEqual(E.target(.zone45, age: 70, sex: .female), 7)
        XCTAssertEqual(E.target(.restingHR, age: 40, sex: .female), 64)
    }

    /// Targets taper with age, so a birthday never moves the age by more than a sliver.
    func testNoJumpOnABirthday() {
        let x = { (age: Double) in E.compute(.init(age: age, sex: .male, dailySteps: 6000, zone13MinPerWeek: 80,
                                                    zone45MinPerWeek: 8))!.deltaYears }
        for age in stride(from: 45.0, through: 75.0, by: 1.0) {
            XCTAssertLessThan(abs(x(age + 1.0 / 365) - x(age)), 0.01, "at \(age)")
        }
    }

    /// More than 40 min of strength per week subtracts years; below 70 % consistency keeps adding.
    func testStrengthAboveTargetAndIrregularSleepStillCount() {
        let strength = { (m: Double) in E.compute(.init(age: 30, sex: .male, strengthMinPerWeek: m))!.deltaYears }
        XCTAssertLessThan(strength(60), strength(40) - 0.1)
        XCTAssertEqual(strength(150), strength(120), accuracy: 1e-9)
        let consistency = { (c: Double) in E.compute(.init(age: 30, sex: .male, sleepConsistencyPct: c))!.deltaYears }
        XCTAssertGreaterThan(consistency(50), consistency(64) + 0.3)
    }

    /// Only a result with every required component counts as complete; lean mass is optional.
    func testCompleteness() {
        var x = E.Inputs(age: 30, sex: .male, sleepHours: 7, sleepConsistencyPct: 70, dailySteps: 8000,
                         zone13MinPerWeek: 100, zone45MinPerWeek: 10, strengthMinPerWeek: 40, vo2max: 44,
                         restingHR: 60)
        XCTAssertTrue(E.compute(x)!.isComplete)
        x.vo2max = nil
        XCTAssertFalse(E.compute(x)!.isComplete)
    }

    /// Far below the VO₂max target, progress must stay visible: past 4 MET under target every ml/kg/min still
    /// counts at half the slope, continuously at the knee. Above target the 4-MET cap stays hard.
    func testVO2maxProgressVisibleFarBelowTarget() {
        let at = { (v: Double) in E.compute(.init(age: 35, sex: .male, vo2max: v))!.deltaYears }   // target 42
        let perMlFull = -10 * log(0.87) / 3.5 * E.overlapFactor
        XCTAssertEqual(at(23) - at(26), 3 * perMlFull / 2, accuracy: 1e-9)
        XCTAssertEqual(at(28) - at(29), perMlFull, accuracy: 1e-9)
        XCTAssertEqual(at(27.9999) - at(28.0001), perMlFull * 0.0001 * 1.5, accuracy: 1e-9)   // no step at the knee
        XCTAssertEqual(at(56), at(70), accuracy: 1e-9)
    }

    /// Body fat below the lean-mass target takes no years off (AI-27): the study's J-shaped curve shows no further
    /// benefit there. Above the target every point still adds years.
    func testBodyFatBelowTargetEarnsNothing() {
        let at = { (lean: Double, sex: E.Sex) in E.compute(.init(age: 30, sex: sex, leanMassPct: lean))!.deltaYears }
        XCTAssertEqual(at(80, .male), 0, accuracy: 1e-9)
        XCTAssertEqual(at(83, .male), 0, accuracy: 1e-9)
        XCTAssertEqual(at(90, .male), 0, accuracy: 1e-9)
        XCTAssertEqual(at(72, .female), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(at(77, .male), 0.1)
        XCTAssertNil(E.levers(.init(age: 30, sex: .male, leanMassPct: 80)).first { $0.component == .leanMass })
    }

    /// Body fat above the ceiling is not extrapolated.
    func testBodyFatCeiling() {
        let a = E.compute(.init(age: 30, sex: .male, leanMassPct: 50))!.deltaYears
        let b = E.compute(.init(age: 30, sex: .male, leanMassPct: 35))!.deltaYears
        XCTAssertEqual(a, b, accuracy: 1e-9)
    }

    /// Pace of Aging: unchanged habits age at 1.0x; healthier last 30 days slow it; values stay in [-1, 3].
    func testPaceOfAging() {
        let sixMonths = E.Inputs(age: 40, sex: .male, sleepHours: 6.5, sleepConsistencyPct: 65, dailySteps: 6000,
                                 zone13MinPerWeek: 60, zone45MinPerWeek: 5, strengthMinPerWeek: 20,
                                 vo2max: 38, restingHR: 64)
        XCTAssertEqual(E.paceOfAging(window: sixMonths, last30Days: sixMonths)!, 1.0, accuracy: 1e-9)

        var healthier = sixMonths
        healthier.dailySteps = 9000; healthier.zone13MinPerWeek = 150; healthier.strengthMinPerWeek = 60
        XCTAssertLessThan(E.paceOfAging(window: sixMonths, last30Days: healthier)!, 1.0)

        var muchWorse = sixMonths
        muchWorse.sleepHours = 4; muchWorse.dailySteps = 2000; muchWorse.zone13MinPerWeek = 0
        muchWorse.zone45MinPerWeek = 0; muchWorse.strengthMinPerWeek = 0; muchWorse.restingHR = 85
        XCTAssertEqual(E.paceOfAging(window: sixMonths, last30Days: muchWorse)!, 3.0)

        var muchBetter = sixMonths
        muchBetter.sleepHours = 8; muchBetter.sleepConsistencyPct = 90; muchBetter.dailySteps = 12000
        muchBetter.zone13MinPerWeek = 400; muchBetter.zone45MinPerWeek = 60; muchBetter.strengthMinPerWeek = 60
        muchBetter.restingHR = 52; muchBetter.vo2max = 48
        XCTAssertEqual(E.paceOfAging(window: sixMonths, last30Days: muchBetter)!, -1.0)
    }
}

final class HealthspanZoneMinutesTests: XCTestCase {

    /// RHR 60, max 190: reserve 130, so 40 % = 112 bpm and 80 % = 164 bpm.
    private func minutes(at bpm: [Int]) -> (zone13: Double, zone45: Double)? {
        let hr = bpm.enumerated().map { HRSample(ts: 1_000_000 + $0.offset * 60, bpm: $0.element) }
        return HealthspanEngine.zoneMinutes(hr: hr, restingHR: 60, maxHR: 190)
    }

    func testBandsFollowHeartRateReserve() {
        let m = minutes(at: [100, 111, 112, 140, 163, 164, 180, 190])!
        XCTAssertEqual(m.zone13, 3, accuracy: 1e-9)   // 112, 140, 163
        XCTAssertEqual(m.zone45, 3, accuracy: 1e-9)   // 164, 180, 190
    }

    /// Dropouts are credited at most 2 minutes, the same rule strain uses.
    func testGapsAreCappedLikeStrain() {
        let hr = [HRSample(ts: 0, bpm: 140), HRSample(ts: 600, bpm: 140), HRSample(ts: 660, bpm: 140)]
        let m = HealthspanEngine.zoneMinutes(hr: hr, restingHR: 60, maxHR: 190)!
        XCTAssertEqual(m.zone13, 2 + 1 + 1, accuracy: 1e-9)
    }

    func testInvalidReserveIsNil() {
        XCTAssertNil(HealthspanEngine.zoneMinutes(hr: [HRSample(ts: 0, bpm: 120)], restingHR: 60, maxHR: 60))
        XCTAssertEqual(HealthspanEngine.zoneMinutes(hr: [], restingHR: 60, maxHR: 190)!.zone13, 0)
    }

    func testWeeklyAverage() {
        XCTAssertEqual(HealthspanEngine.perWeek(totalMinutes: 300, days: 30)!, 70, accuracy: 1e-9)
        XCTAssertNil(HealthspanEngine.perWeek(totalMinutes: 300, days: 0))
    }
}
