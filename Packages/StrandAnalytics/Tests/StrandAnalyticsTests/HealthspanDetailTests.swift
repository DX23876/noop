import XCTest
@testable import StrandAnalytics

final class HealthspanDetailTests: XCTestCase {

    private typealias E = HealthspanEngine

    /// Each bar spans a fixed range and its ticks carry exactly the years the engine assigns that value,
    /// so a marker placed on the bar reads the same number as the row's figure.
    func testBarTicksMatchTheEngine() {
        for c in E.Component.allCases {
            let s = E.barScale(c, age: 35, sex: .male)
            XCTAssertLessThan(s.range.lowerBound, s.range.upperBound, "\(c)")
            XCTAssertEqual(s.ticks.count, E.barTickCount)
            XCTAssertEqual(s.ticks.first!.value, s.range.lowerBound, accuracy: 1e-9)
            XCTAssertEqual(s.ticks.last!.value, s.range.upperBound, accuracy: 1e-9)
            for t in s.ticks {
                var x = E.Inputs(age: 35, sex: .male); x.set(c, t.value)
                XCTAssertEqual(t.years, E.compute(x)!.deltaYears, accuracy: 1e-9, "\(c) at \(t.value)")
            }
        }
        // The target sits where the years cross zero.
        let steps = E.barScale(.dailySteps, age: 35, sex: .male)
        XCTAssertTrue(steps.ticks.first!.years > 0 && steps.ticks.last!.years < 0)
        XCTAssertEqual(E.barScale(.vo2max, age: 35, sex: .male).range, 22...62)
    }

    func testPaceClasses() {
        XCTAssertEqual(E.PaceClass(pace: -0.2), .reversing)
        XCTAssertEqual(E.PaceClass(pace: 0.5), .slowing)
        XCTAssertEqual(E.PaceClass(pace: 1.0), .steady)
        XCTAssertEqual(E.PaceClass(pace: 1.6), .accelerating)
    }

    /// The status line picks its case from the delta and the pace, and names the strongest helper and lever.
    func testNarrative() {
        let x = E.Inputs(age: 35, sex: .male, sleepHours: 7.49, sleepConsistencyPct: 56.9, dailySteps: 9646,
                         zone13MinPerWeek: 284, zone45MinPerWeek: 6.1, strengthMinPerWeek: 23, vo2max: 23.1,
                         restingHR: 66.1)
        let r = E.compute(x)!
        let n = E.narrative(result: r, pace: 0.6, levers: E.levers(x))
        XCTAssertEqual(n.kind, .olderImproving)
        XCTAssertEqual(n.helper, .zone13)
        XCTAssertEqual(n.lever, .sleepConsistency)
        XCTAssertEqual(E.narrative(result: r, pace: 1.4, levers: []).kind, .olderAccelerating)
        XCTAssertNil(E.narrative(result: r, pace: nil, levers: []).lever)

        let young = E.compute(E.Inputs(age: 35, sex: .male, dailySteps: 12000))!
        XCTAssertEqual(E.narrative(result: young, pace: 1.0, levers: []).kind, .youngerSteady)
        XCTAssertEqual(E.narrative(result: young, pace: 1.5, levers: []).kind, .youngerAccelerating)
    }

    /// A falling age leads the status, younger or older.
    func testReversingPaceLeads() {
        let x = E.Inputs(age: 30, sex: .male, sleepHours: 6, sleepConsistencyPct: 60, dailySteps: 5000,
                         restingHR: 70)
        let r = E.compute(x)!
        XCTAssertGreaterThan(r.deltaYears, 0)
        XCTAssertEqual(E.narrative(result: r, pace: -0.4, levers: []).kind, .reversing)
        XCTAssertEqual(E.narrative(result: r, pace: 0.4, levers: []).kind, .olderImproving)
    }

    /// The arrow follows the value; its colour follows the years; small shifts get none.
    func testTrendArrow() {
        let lowerHR = E.trend(windowValue: 60, recentValue: 56, windowYears: 0.4, recentYears: 0.1)!
        XCTAssertFalse(lowerHR.rising)
        XCTAssertTrue(lowerHR.better)
        let fewerSteps = E.trend(windowValue: 9000, recentValue: 7000, windowYears: -0.5, recentYears: -0.2)!
        XCTAssertFalse(fewerSteps.rising)
        XCTAssertFalse(fewerSteps.better)
        XCTAssertNil(E.trend(windowValue: 9000, recentValue: 9100, windowYears: -0.5, recentYears: -0.55))
    }
}
