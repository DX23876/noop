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

    /// The four published anchors (whitepaper Table 2, 30-year-olds). Ranges in the paper use their midpoint;
    /// the unknown US Zone 4-5 time is 0. Tolerance ±0.5 y, fixed before the curves were written.
    func testWhitepaperTable2Anchors() {
        let usMale = E.compute(.init(age: 30, sex: .male, sleepHours: 6.35, sleepConsistencyPct: 65,
                                     dailySteps: 5200, zone13MinPerWeek: 69, zone45MinPerWeek: 0,
                                     strengthMinPerWeek: 0, vo2max: 42.4, restingHR: 67, leanMassPct: 73.9))!
        let whoopMale = E.compute(.init(age: 30, sex: .male, sleepHours: 7.0, sleepConsistencyPct: 67,
                                        dailySteps: 10900, zone13MinPerWeek: 141, zone45MinPerWeek: 6,
                                        strengthMinPerWeek: 46, vo2max: 46.8, restingHR: 58, leanMassPct: 81))!
        let usFemale = E.compute(.init(age: 30, sex: .female, sleepHours: 6.35, sleepConsistencyPct: 65,
                                       dailySteps: 5000, zone13MinPerWeek: 46, zone45MinPerWeek: 0,
                                       strengthMinPerWeek: 0, vo2max: 30.2, restingHR: 72, leanMassPct: 62.2))!
        let whoopFemale = E.compute(.init(age: 30, sex: .female, sleepHours: 7.3, sleepConsistencyPct: 68,
                                          dailySteps: 11500, zone13MinPerWeek: 124, zone45MinPerWeek: 7,
                                          strengthMinPerWeek: 56, vo2max: 40, restingHR: 63, leanMassPct: 73))!
        XCTAssertEqual(usMale.deltaYears, 6.0, accuracy: 0.5)
        XCTAssertEqual(whoopMale.deltaYears, -1.6, accuracy: 0.5)
        XCTAssertEqual(usFemale.deltaYears, 7.5, accuracy: 0.5)
        XCTAssertEqual(whoopFemale.deltaYears, -1.6, accuracy: 0.5)
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
        // Over 9 h of sleep has no effect, by the whitepaper's rule.
        XCTAssertEqual(E.compute(.init(age: 30, sex: .male, sleepHours: 10))!.deltaYears, 0, accuracy: 1e-9)
    }

    /// Age- and sex-dependent targets follow the whitepaper tables.
    func testTargets() {
        XCTAssertEqual(E.vo2maxTarget(age: 30, sex: .male), 44)
        XCTAssertEqual(E.vo2maxTarget(age: 32.5, sex: .male), 43, accuracy: 1e-9)
        XCTAssertEqual(E.vo2maxTarget(age: 18, sex: .female), 40)
        XCTAssertEqual(E.vo2maxTarget(age: 110, sex: .female), 18)
        XCTAssertEqual(E.target(.dailySteps, age: 45, sex: .male), 8000)
        XCTAssertEqual(E.target(.dailySteps, age: 65, sex: .male), 5600)
        XCTAssertEqual(E.target(.zone13, age: 65, sex: .female), 70)
        XCTAssertEqual(E.target(.zone45, age: 65, sex: .female), 7)
        XCTAssertEqual(E.target(.restingHR, age: 40, sex: .female), 64)
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
