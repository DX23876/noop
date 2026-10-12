import XCTest
@testable import StrandAnalytics

final class HealthspanWindowTests: XCTestCase {

    private typealias W = HealthspanWindow

    /// `n` consecutive days ending on `end`, every day carrying the same values.
    private func days(_ n: Int, end: String, sleep: Double? = 7, steps: Double? = 8000, hr: Double? = 60,
                      consistency: Double? = 70, z13: Double? = 100.0 / 7, z45: Double? = 10.0 / 7,
                      strength: Double? = 40.0 / 7) -> [HealthspanDay] {
        (0..<n).map { i in
            HealthspanDay(day: W.dayKey(end, plus: i - (n - 1)), sleepHours: sleep, steps: steps, sleepMeanHR: hr,
                          sleepConsistencyPct: consistency, zone13Min: z13, zone45Min: z45, strengthMin: strength)
        }
    }

    func testDayKeyArithmetic() {
        XCTAssertEqual(W.dayKey("2026-03-01", plus: -1), "2026-02-28")
        XCTAssertEqual(W.dayKey("2026-12-31", plus: 1), "2027-01-01")
    }

    /// Averages per day for sleep, steps, HR and consistency; weekly rates for zone and strength minutes.
    func testInputsAverageTheWindow() {
        let x = W.inputs(days: days(60, end: "2026-10-10"), endingOn: "2026-10-10", windowDays: 182,
                         age: 30, sex: .male, vo2max: 44, leanMassPct: nil)!
        XCTAssertEqual(x.sleepHours!, 7, accuracy: 1e-9)
        XCTAssertEqual(x.dailySteps!, 8000, accuracy: 1e-9)
        XCTAssertEqual(x.restingHR!, 60, accuracy: 1e-9)
        XCTAssertEqual(x.sleepConsistencyPct!, 70, accuracy: 1e-9)
        XCTAssertEqual(x.zone13MinPerWeek!, 100, accuracy: 1e-9)
        XCTAssertEqual(x.zone45MinPerWeek!, 10, accuracy: 1e-9)
        XCTAssertEqual(x.strengthMinPerWeek!, 40, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.compute(x)!.deltaYears, 0, accuracy: 1e-9)
    }

    /// Days outside the window, and days after its end, are ignored.
    func testWindowBounds() {
        var d = days(10, end: "2026-10-10", steps: 1000)
        d += days(30, end: "2026-10-01", steps: 9000).map { HealthspanDay(day: $0.day, steps: $0.steps) }
        let x = W.inputs(days: d, endingOn: "2026-09-30", windowDays: 7, age: 30, sex: .male,
                         vo2max: nil, leanMassPct: nil)!
        XCTAssertEqual(x.dailySteps!, 9000, accuracy: 1e-9)
    }

    /// Zone minutes only count days whose HR was banked; strength counts every day of the covered span,
    /// because workouts are kept for good while raw HR is not.
    func testZoneAndStrengthCoverage() {
        var d = days(28, end: "2026-10-10", z13: nil, z45: nil, strength: 0)
        for i in 21..<28 { d[i].zone13Min = 30; d[i].zone45Min = 0 }   // only the last week has banked HR
        d[27].strengthMin = 56
        let x = W.inputs(days: d, endingOn: "2026-10-10", windowDays: 182, age: 30, sex: .male,
                         vo2max: nil, leanMassPct: nil)!
        XCTAssertEqual(x.zone13MinPerWeek!, 210, accuracy: 1e-9)
        XCTAssertEqual(x.strengthMinPerWeek!, 56.0 / 28 * 7, accuracy: 1e-9)

        for i in 21..<26 { d[i].zone13Min = nil }   // fewer than 7 banked days: too thin to state a rate
        XCTAssertNil(W.inputs(days: d, endingOn: "2026-10-10", windowDays: 182, age: 30, sex: .male,
                              vo2max: nil, leanMassPct: nil)!.zone13MinPerWeek)
    }

    /// A week's result: provisional until the window is full, nothing before 30 nights of sleep.
    func testWeeklyGatesAndPace() {
        XCTAssertNil(W.weekly(days: days(29, end: "2026-10-10"), endingOn: "2026-10-10", age: 30, sex: .male,
                              vo2max: 44, leanMassPct: nil))
        let early = W.weekly(days: days(40, end: "2026-10-10"), endingOn: "2026-10-10", age: 30, sex: .male,
                             vo2max: 44, leanMassPct: nil)!
        XCTAssertTrue(early.isProvisional)
        XCTAssertEqual(early.coveredDays, 40)
        XCTAssertEqual(early.pace!, 1.0, accuracy: 1e-9)
        let full = W.weekly(days: days(200, end: "2026-10-10"), endingOn: "2026-10-10", age: 30, sex: .male,
                            vo2max: 44, leanMassPct: nil)!
        XCTAssertFalse(full.isProvisional)
        XCTAssertEqual(full.coveredDays, 182)
        XCTAssertEqual(full.result.healthspanAge, 30, accuracy: 1e-9)
    }

    /// No age without the four measures the band always supplies; any other gap still yields one, and the
    /// result says how many measures it stands on.
    func testCoreComponentsGateTheAge() {
        XCTAssertNil(W.weekly(days: days(40, end: "2026-10-10", consistency: nil), endingOn: "2026-10-10",
                              age: 30, sex: .male, vo2max: 44, leanMassPct: nil))
        XCTAssertNil(W.weekly(days: days(40, end: "2026-10-10", hr: nil), endingOn: "2026-10-10",
                              age: 30, sex: .male, vo2max: 44, leanMassPct: nil))
        let noVO2 = W.weekly(days: days(40, end: "2026-10-10"), endingOn: "2026-10-10", age: 30, sex: .male,
                             vo2max: nil, leanMassPct: nil)!
        XCTAssertEqual(noVO2.result.componentsUsed, 7)
    }

    /// The pace uses its own VO₂max when one is given, so fitness moves the pace.
    func testRecentVO2maxDrivesThePace() {
        let same = W.weekly(days: days(40, end: "2026-10-10"), endingOn: "2026-10-10", age: 30, sex: .male,
                            vo2max: 44, leanMassPct: nil)!
        let fitter = W.weekly(days: days(40, end: "2026-10-10"), endingOn: "2026-10-10", age: 30, sex: .male,
                              vo2max: 44, recentVO2max: 48, leanMassPct: nil)!
        XCTAssertEqual(same.pace!, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(fitter.pace!, 1.0)
        XCTAssertEqual(fitter.result.healthspanAge, same.result.healthspanAge, accuracy: 1e-9)
    }

    /// The latest VO₂max on or before the week, within the window.
    func testLatestValue() {
        let v = [(day: "2026-01-01", value: 30.0), (day: "2026-09-01", value: 33.0), (day: "2026-11-01", value: 40.0)]
        XCTAssertEqual(W.latest(v, onOrBefore: "2026-10-10", withinDays: 182), 33)
        XCTAssertNil(W.latest(v, onOrBefore: "2026-08-01", withinDays: 100))
    }

    func testStrengthAndSexMapping() {
        for name in ["Strength Training", "Functional strength training", "Bodybuilding", "Yoga", "Pilates",
                     "HIIT", "Rucking", "Barre"] {
            XCTAssertTrue(W.countsAsStrength(storedName: name), name)
        }
        for name in ["Walking", "detected", "Cycling", "Stretching"] {
            XCTAssertFalse(W.countsAsStrength(storedName: name), name)
        }
        XCTAssertEqual(HealthspanEngine.Sex(profileValue: "male"), .male)
        XCTAssertEqual(HealthspanEngine.Sex(profileValue: "female"), .female)
        XCTAssertNil(HealthspanEngine.Sex(profileValue: "nonbinary"))
    }
}
