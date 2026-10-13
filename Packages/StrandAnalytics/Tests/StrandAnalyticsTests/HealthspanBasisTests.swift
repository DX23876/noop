import XCTest
@testable import StrandAnalytics

final class HealthspanBasisTests: XCTestCase {

    private typealias B = HealthspanBasis
    private let end = "2026-10-10"

    /// `n` consecutive days ending on `end`; every other day carries steps and zone minutes, every fifth a session.
    private func days(_ n: Int) -> [HealthspanDay] {
        (0..<n).map { i in
            HealthspanDay(day: HealthspanWindow.dayKey(end, plus: i - (n - 1)), sleepHours: 7,
                          steps: i % 2 == 0 ? 8000 : nil, sleepMeanHR: 60, sleepConsistencyPct: i < 4 ? nil : 70,
                          zone13Min: i % 2 == 0 ? 15 : nil, zone45Min: i % 2 == 0 ? 2 : nil, strengthMin: 0,
                          strengthSessions: i % 5 == 0 ? 1 : 0)
        }
    }

    /// The counts come from the window days the week is averaged over, so they live on the week itself.
    func testCountsComeWithTheWeek() {
        let w = HealthspanWindow.weekly(days: days(60), endingOn: end, age: 35, sex: .male, vo2max: nil,
                                        leanMassPct: nil)!
        XCTAssertEqual(w.counts[.sleepDuration], 60)
        XCTAssertEqual(w.counts[.sleepConsistency], 56)
        XCTAssertEqual(w.counts[.dailySteps], 30)
        XCTAssertEqual(w.counts[.restingHR], 60)
        XCTAssertEqual(w.counts[.zone13], 30)
        XCTAssertEqual(w.counts[.zone45], 30)
        XCTAssertEqual(w.counts[.strength], 12)
        XCTAssertNil(w.counts[.vo2max])
        XCTAssertNil(w.counts[.leanMass])
        XCTAssertEqual(w.coveredDays, 60)
    }

    /// Only days inside the 182-day window count.
    func testCountsStopAtTheWindow() {
        let w = HealthspanWindow.weekly(days: days(200), endingOn: end, age: 35, sex: .male, vo2max: nil,
                                        leanMassPct: nil)!
        XCTAssertEqual(w.counts[.sleepDuration], 182)
    }

    /// A daily measure is thin below 60 % of the days the window covers; the share is of the covered span, so a
    /// young window is judged on what it could have held.
    func testDailyMeasuresThinBelowSixtyPercent() {
        let ok = B.line(.dailySteps, count: 110, coveredDays: 182, vo2Source: nil, latestDay: nil, weekEnd: end)
        XCTAssertEqual(ok, .init(kind: .days(count: 110, of: 182), isThin: false))
        let thin = B.line(.dailySteps, count: 109, coveredDays: 182, vo2Source: nil, latestDay: nil, weekEnd: end)
        XCTAssertEqual(thin?.isThin, true)
        XCTAssertEqual(B.line(.sleepDuration, count: 30, coveredDays: 40, vo2Source: nil, latestDay: nil,
                              weekEnd: end), .init(kind: .days(count: 30, of: 40), isThin: false))
        XCTAssertEqual(B.line(.restingHR, count: 200, coveredDays: 400, vo2Source: nil, latestDay: nil,
                              weekEnd: end)?.kind, .days(count: 200, of: 182))
        XCTAssertNil(B.line(.sleepConsistency, count: nil, coveredDays: 182, vo2Source: nil, latestDay: nil,
                            weekEnd: end))
    }

    /// Zone minutes are thin under four banked weeks; strength never is, since no sessions is a fact.
    func testZoneAndStrength() {
        XCTAssertEqual(B.line(.zone13, count: 27, coveredDays: 182, vo2Source: nil, latestDay: nil, weekEnd: end),
                       .init(kind: .zoneDays(count: 27), isThin: true))
        XCTAssertEqual(B.line(.zone45, count: 28, coveredDays: 182, vo2Source: nil, latestDay: nil, weekEnd: end)?
            .isThin, false)
        XCTAssertEqual(B.line(.strength, count: 0, coveredDays: 182, vo2Source: nil, latestDay: nil, weekEnd: end),
                       .init(kind: .sessions(count: 0), isThin: false))
    }

    /// Only a training estimate on fewer than three walks and runs is thin; an entered value has its own hint.
    func testVO2max() {
        XCTAssertEqual(B.line(.vo2max, count: 2, coveredDays: 182, vo2Source: .training, latestDay: "2026-10-01",
                              weekEnd: end),
                       .init(kind: .vo2max(source: .training, readings: 2, latestDay: "2026-10-01"), isThin: true))
        XCTAssertEqual(B.line(.vo2max, count: 3, coveredDays: 182, vo2Source: .training, latestDay: "2026-10-01",
                              weekEnd: end)?.isThin, false)
        XCTAssertEqual(B.line(.vo2max, count: 1, coveredDays: 182, vo2Source: .appleHealth,
                              latestDay: "2026-10-01", weekEnd: end)?.isThin, false)
        XCTAssertEqual(B.line(.vo2max, count: 1, coveredDays: 182, vo2Source: .manual, latestDay: "2025-12-01",
                              weekEnd: end)?.isThin, false)
        XCTAssertNil(B.line(.vo2max, count: nil, coveredDays: 182, vo2Source: nil, latestDay: nil, weekEnd: end))
    }

    /// Body fat older than 90 days before the week's end is thin.
    func testBodyFatAge() {
        XCTAssertEqual(B.line(.leanMass, count: nil, coveredDays: 182, vo2Source: nil,
                              latestDay: HealthspanWindow.dayKey(end, plus: -90), weekEnd: end)?.isThin, false)
        XCTAssertEqual(B.line(.leanMass, count: nil, coveredDays: 182, vo2Source: nil,
                              latestDay: HealthspanWindow.dayKey(end, plus: -91), weekEnd: end),
                       .init(kind: .bodyFat(day: HealthspanWindow.dayKey(end, plus: -91)), isThin: true))
    }

    /// The VO₂max resolver names the newest reading behind the window, or the day an entered value was measured.
    func testResolvedLatestDay() {
        let apple = [(day: "2026-05-01", value: 44.0), (day: "2026-09-20", value: 45.0),
                     (day: "2026-10-20", value: 46.0)]
        let r = HealthspanVO2.resolve(manual: nil, appleHealth: apple, training: [], endingOn: end)!
        XCTAssertEqual(r.latestDay, "2026-09-20")
        XCTAssertEqual(r.readings, 2)
        let m = HealthspanVO2.resolve(manual: (day: "2026-08-01", value: 48), appleHealth: apple, training: [],
                                      endingOn: end)!
        XCTAssertEqual(m.latestDay, "2026-08-01")
    }

    /// Lean mass and its basis come from the same body-fat reading.
    func testLatestBodyFat() {
        let fat = [(day: "2026-06-01", value: 25.0), (day: "2026-09-01", value: 22.0),
                   (day: "2026-11-01", value: 20.0), (day: "2026-09-15", value: 140.0)]
        XCTAssertEqual(HealthspanVO2.latestBodyFat(fat, endingOn: end)?.day, "2026-09-01")
        XCTAssertEqual(HealthspanVO2.leanMassPct(bodyFat: fat, endingOn: end), 78)
    }

    /// Reading days survive the numeric store unchanged; anything that is not a day comes back nil.
    func testDayNumbersRoundTrip() {
        XCTAssertEqual(B.dayNumber("2026-10-03"), 20261003)
        XCTAssertEqual(B.dayKey(number: 20261003), "2026-10-03")
        XCTAssertEqual(B.dayKey(number: B.dayNumber("2024-02-29")!), "2024-02-29")
        XCTAssertNil(B.dayNumber("not a day"))
        XCTAssertNil(B.dayKey(number: 20261003.5))
        XCTAssertNil(B.dayKey(number: 20261341))
    }
}
