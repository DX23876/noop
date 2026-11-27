import XCTest
@testable import StrandAnalytics

/// The weight page's one derivation (owner decisions 2026-11-26): forecasts that say when they cannot answer,
/// events, milestones reached by a real weigh-in, the log's trend columns and the monthly reports.
final class WeightTrackerTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()
    /// Noon on 2026-11-26, Berlin.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 12))! }

    /// One weigh-in a day for `days` days up to today, falling `perDay` kilograms a day from `start`.
    private func line(days: Int, start: Double, perDay: Double) -> [WeightTracker.Reading] {
        (0..<days).map { i in
            let date = now.addingTimeInterval(-Double(days - 1 - i) * 86_400 - 3_600 * 4)
            return WeightTracker.Reading(date: date, kg: start - perDay * Double(i), id: "w\(i)", source: "manual")
        }
    }

    private func snap(_ readings: [WeightTracker.Reading], goal: WeightTracker.Goal? = nil, plan: Double? = nil,
                      settings: WeightTracker.Settings = .standard, events: [WeightTracker.Event] = []) -> WeightTracker.Snapshot {
        WeightTracker.snapshot(.init(readings: readings, goal: goal, planKgPerWeek: plan, settings: settings,
                                     events: events, now: now, calendar: cal))!
    }

    func testNothingToShowWithoutAPlausibleWeighIn() {
        XCTAssertNil(WeightTracker.snapshot(.init(readings: [], now: now)))
        XCTAssertNil(WeightTracker.snapshot(.init(readings: [.init(date: now, kg: 0)], now: now)))
    }

    func testTheCurrentRateFollowsTheTrendAndDrivesTheArrival() {
        let s = snap(line(days: 60, start: 110, perDay: 0.1),
                     goal: .init(baseline: 110, target: 100, createdAt: now.addingTimeInterval(-60 * 86_400)))
        let rate = try! XCTUnwrap(s.rates.currentKgPerWeek)
        XCTAssertEqual(rate, -0.7, accuracy: 0.15, "a tenth of a kilo a day is about 0.7 a week")
        XCTAssertEqual(s.forecast.state, .arriving)
        XCTAssertNotNil(s.forecast.targetDate)
        XCTAssertEqual(s.changes.map(\.days), [7, 30, nil], "no 90-day change from 60 days of history")
    }

    func testNoDateWhenTheTrendMovesAwayOrTheHistoryIsShort() {
        let away = snap(line(days: 40, start: 100, perDay: -0.05),
                        goal: .init(baseline: 100, target: 95, createdAt: now.addingTimeInterval(-40 * 86_400)))
        XCTAssertEqual(away.forecast.state, .movingAway)
        XCTAssertNil(away.forecast.targetDate)
        let short = snap(line(days: 5, start: 100, perDay: 0.1),
                         goal: .init(baseline: 100, target: 95, createdAt: now.addingTimeInterval(-5 * 86_400)))
        XCTAssertEqual(short.forecast.state, .notEnoughData, "five days are too few for a rate")
        XCTAssertNil(short.rates.currentKgPerWeek)
    }

    func testAMaintainGoalReadsTheBandNotADate() {
        let s = snap(line(days: 30, start: 80, perDay: 0),
                     goal: .init(baseline: 80, target: 80, createdAt: now.addingTimeInterval(-30 * 86_400), band: 1.5))
        XCTAssertEqual(s.forecast.state, .withinBand)
        XCTAssertNil(s.milestones, "a maintain goal has no route")
    }

    func testTheTenDayLowIsOnlyTheStartPoint() {
        var readings = line(days: 30, start: 90, perDay: 0)
        readings[27].kg = 88   // a dry morning three days ago
        var settings = WeightTracker.Settings.standard
        settings.basis = .tenDayLow
        let s = snap(readings, settings: settings)
        XCTAssertEqual(s.forecast.startKg, 88)
        XCTAssertEqual(s.forecast.basis, .tenDayLow)
        XCTAssertEqual(s.trendKg, 90, accuracy: 0.5, "the trend itself is not moved by the option")
    }

    func testThePlannedRateComesFromThePlanThenTheGoalThenTheWearer() {
        let readings = line(days: 30, start: 100, perDay: 0.05)
        let dated = WeightTracker.Goal(baseline: 100, target: 90, createdAt: now.addingTimeInterval(-30 * 86_400),
                                       targetDate: now.addingTimeInterval(70 * 86_400))
        XCTAssertEqual(snap(readings, goal: dated, plan: -0.5).rates.wishSource, .dietPlan)
        let fromGoal = snap(readings, goal: dated).rates
        XCTAssertEqual(fromGoal.wishSource, .goal)
        XCTAssertEqual(fromGoal.wishKgPerWeek!, -0.7, accuracy: 0.01, "ten kilos over the goal's hundred days")
        var settings = WeightTracker.Settings.standard
        settings.manualWishKgPerWeek = -2.0
        let manual = snap(readings, settings: settings).rates
        XCTAssertEqual(manual.wishSource, .manual)
        XCTAssertTrue(manual.wishIsSteep, "two kilos a week is more than 1 % of 100 kg")
    }

    func testAnUpcomingEventGetsThePredictionAndAPassedOneTheComparison() {
        let readings = line(days: 60, start: 100, perDay: 0.1)
        let soon = WeightTracker.Event(name: "Wedding", day: "2026-12-10")
        let past = WeightTracker.Event(name: "Reunion", day: "2026-11-20")
        let old = WeightTracker.Event(name: "Trip", day: "2026-10-01")
        let s = snap(readings, events: [old, past, soon])
        XCTAssertEqual(s.events.map(\.event.name), ["Wedding", "Reunion", "Trip"])
        let wedding = s.events[0]
        XCTAssertEqual(wedding.phase, .upcoming)
        XCTAssertEqual(wedding.daysAway, 14)
        XCTAssertEqual(wedding.predictedKg!, s.forecast.startKg + s.rates.currentKgPerWeek! * 2, accuracy: 0.01)
        let reunion = s.events[1]
        XCTAssertEqual(reunion.phase, .passed)
        XCTAssertNotNil(reunion.measuredKg)
        XCTAssertNotNil(reunion.predictedBeforeKg, "what the forecast said the day before")
        XCTAssertEqual(s.events[2].phase, .archived)
    }

    func testAMilestoneIsReachedByARealWeighIn() {
        let goal = WeightTracker.Goal(baseline: 100, target: 90, createdAt: now.addingTimeInterval(-60 * 86_400))
        var settings = WeightTracker.Settings.standard
        settings.milestoneStepKg = 2
        let s = snap(line(days: 60, start: 100, perDay: 0.1), goal: goal, settings: settings)
        let m = try! XCTUnwrap(s.milestones)
        XCTAssertEqual(m.route.map(\.kg), [98, 96, 94, 92, 90])
        XCTAssertEqual(m.reachedCount, 2, "the scale has read 96 but not 94")
        XCTAssertEqual(m.next, 94)
        let marked = s.log.filter { $0.milestoneKg != nil }.map(\.milestoneKg!)
        XCTAssertEqual(marked.sorted(), [96, 98], "each reached milestone marks the weigh-in that reached it")
    }

    func testTheLogCarriesTheTrendAndItsWeeklyChange() {
        let s = snap(line(days: 20, start: 100, perDay: 0.1))
        XCTAssertEqual(s.log.first?.reading.id, "w19", "newest first")
        XCTAssertNotNil(s.log.first?.weeklyRateKg)
        XCTAssertNil(s.log.last?.weeklyRateKg, "the first weigh-in has no week behind it")
    }

    func testAReportNeedsFourWeighInsAndComparesWithTheMonthBefore() {
        var readings = line(days: 40, start: 100, perDay: 0.05)
        // Leave only three weigh-ins in October.
        readings.removeAll { cal.component(.month, from: $0.date) == 10 && cal.component(.day, from: $0.date) > 20 }
        let s = snap(readings)
        let november = try! XCTUnwrap(s.months.first { $0.key == "2026-11" })
        XCTAssertTrue(november.enough)
        XCTAssertNotNil(november.low)
        let october = try! XCTUnwrap(s.months.first { $0.key == "2026-10" })
        XCTAssertFalse(october.enough, "three weigh-ins are too few")
        XCTAssertNil(november.vsPreviousKg, "a month with too few weigh-ins is no comparison")
        XCTAssertEqual(s.years.map(\.key), ["2026"])
    }

    func testStoredSettingsRoundTripAndTolerateOddValues() {
        var stored = WeightTracker.Stored()
        stored.settings.rateMode = .wish
        stored.events = [.init(id: "e1", name: "Wedding", day: "2027-05-18", createdAt: Date(timeIntervalSince1970: 1_800_000_000))]
        XCTAssertEqual(WeightTracker.Stored.decode(stored.encoded()), stored)
        let odd = WeightTracker.Stored.decode(#"{"settings":{"rateWindowDays":13,"milestoneStepKg":3,"basis":"later"},"x":1}"#)
        XCTAssertEqual(odd.settings.rateWindowDays, 28)
        XCTAssertNil(odd.settings.milestoneStepKg)
        XCTAssertEqual(odd.settings.basis, .trend)
        XCTAssertEqual(WeightTracker.Stored.decode(nil), WeightTracker.Stored())
    }

    func testTheReminderSkipsAWeighedDayAndTheDaysNotChosen() {
        // 2026-11-26 is a Thursday (weekday 5). Seven o'clock has passed at noon.
        let next = WeightTracker.reminderTimes(after: now, minutes: 7 * 60, weekdays: [], weighedInDays: [], count: 2, calendar: cal)
        XCTAssertEqual(next.map { cal.component(.day, from: $0) }, [27, 28])
        let evening = WeightTracker.reminderTimes(after: now, minutes: 20 * 60, weekdays: [], weighedInDays: ["2026-11-26"],
                                                  calendar: cal)
        XCTAssertEqual(evening.map { cal.component(.day, from: $0) }, [27], "today has a weigh-in already")
        let mondays = WeightTracker.reminderTimes(after: now, minutes: 7 * 60, weekdays: [2], weighedInDays: [], count: 2,
                                                  calendar: cal)
        XCTAssertEqual(mondays.map { cal.component(.day, from: $0) }, [30, 7])
    }

    /// Reached is the trend's verdict: one dry morning below the goal is not the goal reached.
    func testADryMorningBelowTheGoalIsNotTheGoalReached() {
        var readings = line(days: 30, start: 86, perDay: 0.02)
        readings[28].kg = 84.6
        var settings = WeightTracker.Settings.standard
        settings.basis = .tenDayLow
        let s = snap(readings, goal: .init(baseline: 90, target: 85, createdAt: now.addingTimeInterval(-60 * 86_400)),
                     settings: settings)
        XCTAssertGreaterThan(s.trendKg, 85)
        XCTAssertNotEqual(s.forecast.state, .reached)
    }
}
