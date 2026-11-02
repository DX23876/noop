import XCTest
@testable import Strand

/// The redesigned Today timeline is assembled, not stored: these pin its ordering, day grouping and how a
/// coach note becomes a headline plus body.
final class ForgeTimelineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_793_520_000)   // a fixed instant
    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }
    private func key(_ d: Date) -> String { String(Int(d.timeIntervalSince1970 / 86_400)) }

    func testNewestFirstAndFutureDropped() {
        var input = ForgeTimeline.Input()
        input.workouts = [
            .init(id: "a", start: at(1), end: at(2), sport: "Run", effort: 40, distanceM: 5000, energyKcal: 300),
            .init(id: "future", start: at(20), end: at(21), sport: "Ride", effort: nil, distanceM: nil, energyKcal: nil),
        ]
        input.weights = [.init(date: at(3), kg: 96.4)]
        input.coach = [.init(id: "c", date: at(0.5), text: "Good morning. Rest well.", origin: .brief)]
        let days = ForgeTimeline.build(input, now: at(10), dayKey: key)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].entries.map(\.id), ["weight-\(Int(at(3).timeIntervalSince1970))", "workout-a", "coach-c"])
    }

    func testDaysAreCapped() {
        var input = ForgeTimeline.Input()
        input.weights = (0..<5).map { .init(date: at(Double($0) * 24 + 1), kg: 90) }
        let days = ForgeTimeline.build(input, now: at(200), days: 2, dayKey: key)
        XCTAssertEqual(days.count, 2)
        XCTAssertGreaterThan(days[0].id, days[1].id)
    }

    func testSplitNoteTakesFirstSentenceAndDropsMarkdown() {
        let split = ForgeTimeline.splitNote("**Well recovered**, push a bit today. HRV is up.\nSleep was long.")
        XCTAssertEqual(split.headline, "Well recovered, push a bit today.")
        XCTAssertEqual(split.body, "HRV is up.\nSleep was long.")
    }

    func testSplitNoteKeepsEmphasisInTheBodyOnly() {
        let split = ForgeTimeline.splitNote("**Solid** night. You slept **7 h 40**, above your need.")
        XCTAssertEqual(split.headline, "Solid night.")
        XCTAssertEqual(split.body, "You slept **7 h 40**, above your need.")
    }

    func testSplitNoteKeepsTheWholeSentenceWhenTheHeadlineIsCut() {
        let long = String(repeating: "word ", count: 40) + "end."
        let split = ForgeTimeline.splitNote(long, maxHeadline: 30)
        XCTAssertTrue(split.headline.hasSuffix("…"))
        XCTAssertLessThanOrEqual(split.headline.count, 31)
        XCTAssertTrue(split.body.hasSuffix("end."))
    }

    func testSplitNoteTakesTheSeededLabelAsKicker() {
        let split = ForgeTimeline.splitNote("Weekly review\n\nThree sessions done. Sleep held up.")
        XCTAssertEqual(split.kicker, "Weekly review")
        XCTAssertEqual(split.headline, "Three sessions done.")
        XCTAssertEqual(split.body, "Sleep held up.")
        XCTAssertNil(ForgeTimeline.splitNote("Rest well tonight.\n\nMore later.").kicker)
    }

    // MARK: ForgeCoachNotes (budget, quiet hours, due workout)

    private var berlin: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }

    private func berlinDate(hour: Int) -> Date {
        berlin.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour))!
    }

    func testNotesRespectBudgetQuietHoursAndSwitch() {
        let noon = berlinDate(hour: 12)
        XCTAssertTrue(ForgeCoachNotes.mayPost(.afterWorkout, now: noon, enabled: true, initiatedToday: 2, calendar: berlin))
        XCTAssertFalse(ForgeCoachNotes.mayPost(.afterWorkout, now: noon, enabled: true, initiatedToday: 3, calendar: berlin))
        XCTAssertFalse(ForgeCoachNotes.mayPost(.afterWorkout, now: noon, enabled: false, initiatedToday: 0, calendar: berlin))
        XCTAssertFalse(ForgeCoachNotes.mayPost(.afterWorkout, now: berlinDate(hour: 23), enabled: true, initiatedToday: 0, calendar: berlin))
        XCTAssertFalse(ForgeCoachNotes.mayPost(.afterWorkout, now: berlinDate(hour: 6), enabled: true, initiatedToday: 0, calendar: berlin))
        XCTAssertFalse(ForgeCoachNotes.mayPost(.evening, now: berlinDate(hour: 18), enabled: true, initiatedToday: 0, calendar: berlin))
        XCTAssertTrue(ForgeCoachNotes.mayPost(.evening, now: berlinDate(hour: 20), enabled: true, initiatedToday: 0, calendar: berlin))
    }

    func testWorkoutDueIsTheNewestUnnotedOneInTheWindow() {
        let now = berlinDate(hour: 18)
        let ends: [(String, Date)] = [("old", berlinDate(hour: 8)), ("a", berlinDate(hour: 15)), ("b", berlinDate(hour: 17))]
        let due = ForgeCoachNotes.workoutDue(ends, now: now, lastNotedId: nil, end: { $0.1 }, id: { $0.0 })
        XCTAssertEqual(due?.0, "b")
        XCTAssertNil(ForgeCoachNotes.workoutDue(ends, now: now, lastNotedId: "b", end: { $0.1 }, id: { $0.0 }))
        XCTAssertNil(ForgeCoachNotes.workoutDue([("old", berlinDate(hour: 8))], now: now, lastNotedId: nil,
                                                end: { $0.1 }, id: { $0.0 }))
    }

    func testSplitNoteWithoutPunctuationAndEmpty() {
        XCTAssertEqual(ForgeTimeline.splitNote("Just a line").headline, "Just a line")
        XCTAssertEqual(ForgeTimeline.splitNote("   ").headline, "")
    }

    // MARK: ForgeToday (hero readouts)

    func testEffortTargetUsesTheCoupledBandsOnTheStoredAxis() {
        let target = ForgeToday.effortTargetStored(charge: 72)
        XCTAssertEqual(target?.lowerBound ?? 0, 14 * 100 / 21, accuracy: 0.001)
        XCTAssertEqual(target?.upperBound ?? 0, 18 * 100 / 21, accuracy: 0.001)
        XCTAssertNil(ForgeToday.effortTargetStored(charge: nil))
    }

    func testTargetPosition() {
        let target = 40.0...60.0
        XCTAssertEqual(ForgeToday.position(effortStored: 39.9, target: target), .below)
        XCTAssertEqual(ForgeToday.position(effortStored: 50, target: target), .inside)
        XCTAssertEqual(ForgeToday.position(effortStored: 60.1, target: target), .above)
    }

    func testEffortTextMatchesTheRingRounding() {
        XCTAssertEqual(ForgeToday.effortText(84.9, scale: .hundred), "85")
        XCTAssertEqual(ForgeToday.effortText(47.0, scale: .hundred), "47")
    }

    func testSummaryNeedsBothEffortAndCharge() {
        XCTAssertNil(ForgeToday.summary(effortStored: nil, charge: 70, scale: .hundred))
        XCTAssertNil(ForgeToday.summary(effortStored: 50, charge: nil, scale: .hundred))
        XCTAssertNotNil(ForgeToday.summary(effortStored: 50, charge: 70, scale: .hundred))
    }

    func testBedtimeIsTomorrowsWakeMinusTheNeed() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 20))!
        let bed = ForgeToday.bedtime(now: now, calendar: cal, wakeMinutes: { _ in 7 * 60 }, sleepNeedMinutes: 8 * 60)
        XCTAssertEqual(bed, cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23)))
    }
}
