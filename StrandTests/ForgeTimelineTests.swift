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

    func testMealsStandAtTheirTimeAsRowsAndFutureMealsWait() {
        var input = ForgeTimeline.Input()
        input.meals = [.init(id: "m1", date: at(2), title: "Breakfast", foods: "Oats", kcal: 420, picture: "motif:grains"),
                       .init(id: "m2", date: at(12), title: "Dinner", foods: "Pasta", kcal: 700, picture: nil)]
        let entries = ForgeTimeline.build(input, now: at(10), dayKey: key)[0].entries
        XCTAssertEqual(entries.map(\.id), ["meal-m1"])
        XCTAssertEqual(entries[0].kind, .meal)
        XCTAssertEqual(entries[0].sourceId, "motif:grains")
        XCTAssertTrue(ForgeTimeline.isRow(.meal))
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

    func testSplitNoteNeverCutsANumber() {
        let split = ForgeTimeline.splitNote("Last night's sleep: you got only **1.7 hours** recorded. That's a problem.")
        XCTAssertEqual(split.headline, "Last night's sleep: you got only 1.7 hours recorded.")
        XCTAssertEqual(split.body, "That's a problem.")
    }

    func testSplitNoteLeavesNoLoneAsterisks() {
        let split = ForgeTimeline.splitNote("That walk held at a steady **13.2/21 effort** today. Good.")
        XCTAssertEqual(split.headline, "That walk held at a steady 13.2/21 effort today.")
        XCTAssertEqual(split.body, "Good.")
        XCTAssertFalse(ForgeTimeline.splitNote("Fine. Half **bold only").body.contains("*"))
    }

    func testSplitNoteDividesALongSentenceAtAClauseAndSaysNothingTwice() {
        let split = ForgeTimeline.splitNote("Your sleep has dropped noticeably over the last three nights — roughly 38% shorter than your recent norm. A real dip.")
        XCTAssertEqual(split.headline, "Your sleep has dropped noticeably over the last three nights.")
        XCTAssertEqual(split.body, "Roughly 38% shorter than your recent norm.\nA real dip.")
        XCTAssertFalse(split.body.contains("Your sleep has dropped"))
    }

    func testSplitNoteKeepsALongSentenceWholeWithoutAClause() {
        let long = String(repeating: "word ", count: 40) + "end."
        let split = ForgeTimeline.splitNote(long, maxHeadline: 30)
        XCTAssertEqual(split.headline, long)
        XCTAssertEqual(split.body, "")
    }

    // MARK: One thing happens once

    func testANoteAboutAWorkoutTakesItsPlaceAtTheMomentItEnded() {
        var input = ForgeTimeline.Input()
        input.workouts = [.init(id: "w", start: at(1), end: at(2), sport: "Run", effort: 40, distanceM: nil, energyKcal: nil),
                          .init(id: "other", start: at(3), end: at(4), sport: "Run", effort: 40, distanceM: nil, energyKcal: nil)]
        input.coach = [.init(id: "c", date: at(5), text: "Strong run.", origin: .nudge, workoutId: "w")]
        let entries = ForgeTimeline.build(input, now: at(10), dayKey: key)[0].entries
        XCTAssertEqual(entries.map(\.id), ["workout-other", "coach-c"])
        XCTAssertEqual(entries[1].date, at(2))
        XCTAssertEqual(entries[1].workoutId, "w")
    }

    func testANoteWithoutABoundWorkoutLeavesWorkoutsAlone() {
        var input = ForgeTimeline.Input()
        input.workouts = [.init(id: "w", start: at(1), end: at(2), sport: "Run", effort: nil, distanceM: nil, energyKcal: nil)]
        input.coach = [.init(id: "c", date: at(3), text: "Old note.", origin: .nudge)]
        let entries = ForgeTimeline.build(input, now: at(10), dayKey: key)[0].entries
        XCTAssertEqual(entries.map(\.id), ["coach-c", "workout-w"])
        XCTAssertNil(entries[0].workoutId)
    }

    func testTheMorningBriefCarriesTheNightItReads() {
        var input = ForgeTimeline.Input()
        input.sleeps = [.init(start: at(-6), end: at(1), minutesAsleep: 400, rest: nil)]
        input.coach = [.init(id: "b", date: at(2), text: "Well rested.", origin: .brief)]
        let entries = ForgeTimeline.build(input, now: at(10), dayKey: key)[0].entries
        XCTAssertEqual(entries.map(\.id), ["coach-b"])
        XCTAssertEqual(entries[0].wake, at(1))
    }

    func testAShortNightStillAppearsWithoutACoach() {
        var input = ForgeTimeline.Input()
        input.sleeps = [.init(start: at(0), end: at(1.8), minutesAsleep: 105, rest: nil)]
        input.naps = [.init(start: at(5), end: at(6), minutesAsleep: 50)]
        let kinds = ForgeTimeline.build(input, now: at(10), dayKey: key)[0].entries.map(\.kind)
        XCTAssertEqual(kinds, [.nap, .wake])
    }

    func testANightEndingBeforeTheRolloverBelongsToTheDayItWakesInto() {
        // A logical day that rolls at 04:00 of `base`, which starts each key here.
        func logical(_ d: Date) -> String { String(Int((d.timeIntervalSince(base) - 4 * 3600) / 86_400 + 1000)) }
        var input = ForgeTimeline.Input()
        input.sleeps = [.init(start: at(1), end: at(2.75), minutesAsleep: 104, rest: nil)]
        input.workouts = [.init(id: "w", start: at(7), end: at(7.5), sport: "Walk", effort: nil, distanceM: nil, energyKcal: nil)]
        let days = ForgeTimeline.build(input, now: at(19), days: 7, dayKey: logical)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].entries.map(\.kind), [.workout, .wake])
    }

    func testDailyFiguresWithoutATimeSitAtTheEndOfTheirDay() {
        var input = ForgeTimeline.Input()
        input.workouts = [.init(id: "w", start: at(1), end: at(2), sport: "Run", effort: nil, distanceM: nil, energyKcal: nil)]
        input.weights = [.init(date: at(0.5), kg: 96, timed: false)]
        let entries = ForgeTimeline.build(input, now: at(10), dayKey: key)[0].entries
        XCTAssertEqual(entries.last?.kind, .weight)
        XCTAssertEqual(entries.last?.timed, false)
    }

    // MARK: What the coach says, and when it stays quiet

    func testAWalkOrAShortOrUnconfirmedSessionGetsNoNote() {
        XCTAssertFalse(ForgeCoachNotes.isWorthANote(sport: "Walking", minutes: 50, isDetected: false))
        XCTAssertFalse(ForgeCoachNotes.isWorthANote(sport: "Running", minutes: 10, isDetected: false))
        XCTAssertFalse(ForgeCoachNotes.isWorthANote(sport: "Running", minutes: 40, isDetected: true))
        XCTAssertTrue(ForgeCoachNotes.isWorthANote(sport: "Running", minutes: 40, isDetected: false))
    }

    func testRepliesComeOnlyFromTheNoteAndAreNeverShownAsText() {
        let asked = ForgeCoachNotes.splitReplies("Tempo held well. Run again tomorrow?\nREPLIES: Yes | Rather rest | Maybe | Never")
        XCTAssertEqual(asked.text, "Tempo held well. Run again tomorrow?")
        XCTAssertEqual(asked.replies, ["Yes", "Rather rest"])
        let plain = ForgeCoachNotes.splitReplies("Tempo held well.")
        XCTAssertEqual(plain.text, "Tempo held well.")
        XCTAssertTrue(plain.replies.isEmpty)
    }

    func testTheCoachIsToldWhatItAlreadySaid() {
        XCTAssertNil(ForgeCoachNotes.alreadySaidClause([]))
        let clause = ForgeCoachNotes.alreadySaidClause(["You slept 1.7 hours."])
        XCTAssertEqual(clause?.contains("You slept 1.7 hours."), true)
        XCTAssertEqual(clause?.contains(ForgeCoachNotes.skipWord), true)
        XCTAssertTrue(ForgeCoachNotes.isSkip(" SKIP.\n"))
        XCTAssertFalse(ForgeCoachNotes.isSkip("SKIP this one tomorrow."))
    }

    func testAnOlderTranscriptStillDecodes() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"Hi"}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertNil(message.workoutId)
        XCTAssertTrue(message.replies.isEmpty)
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

    // MARK: Note kinds and the morning note (2026-11-07)

    func testOlderNudgesKeepTheirKindFromTheirFirstLine() {
        typealias O = ForgeTimeline.CoachNote.Origin
        XCTAssertEqual(O.legacy(nudgeText: "After your workout\n\nSteady walk."), .afterWorkout)
        XCTAssertEqual(O.legacy(nudgeText: "Evening recap\n\nGood day."), .evening)
        XCTAssertEqual(O.legacy(nudgeText: "A quick nudge\n\nSleep is shorter."), .nudge)
        XCTAssertEqual(O.legacy(nudgeText: "After your workout was a long day."), .nudge)
    }

    func testTheNewKindsSurviveTheTranscript() throws {
        for origin in [ChatMessage.Origin.afterWorkout, .evening] {
            let message = ChatMessage(role: .assistant, text: "x", origin: origin)
            let back = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
            XCTAssertEqual(back.origin, origin)
            XCTAssertTrue(back.origin.isCoachInitiated)
        }
    }

    func testTheMorningNoteIsShortCarriesNoFiguresAndProposesOnlyWithTools() {
        let withTools = ForgeCoachNotes.morningInstruction(toolsActive: true)
        let without = ForgeCoachNotes.morningInstruction(toolsActive: false)
        for text in [withTools, without] {
            XCTAssertTrue(text.contains(ForgeCoachNotes.noFiguresClause))
            XCTAssertTrue(text.contains(ForgeCoachNotes.voiceClause))
            XCTAssertTrue(text.contains("under 40 words"))
        }
        XCTAssertTrue(withTools.contains("propose_plan"))
        XCTAssertTrue(withTools.contains("get_plan_adherence"))
        XCTAssertFalse(without.contains("propose_plan"))
        XCTAssertTrue(ForgeCoachNotes.workoutInstruction(sport: "Run", minutes: 30, ended: "18:00")
            .contains(ForgeCoachNotes.noFiguresClause))
        XCTAssertTrue(ForgeCoachNotes.eveningInstruction().contains(ForgeCoachNotes.noFiguresClause))
    }

    // MARK: Figures in notes

    /// The note of 3 November 2026, against what the tools returned: the true figures stay, "HRV 50" over
    /// a stored 44, "Charge 30" over 25 and an Effort on the 0 to 21 scale go.
    func testTheGuardStrikesFiguresTheCoachNeverRead() {
        let note = "**You got only 1.7 hours recorded, with 3 disturbances.** Your HRV is still at 50 ms and your Charge is stuck at 30.\n\nBed by 22:30 tonight. The walk held a steady **13.2/21 effort**. Charge 25 is low."
        let tools = ["{\"sleep_min\":104,\"disturbances\":3,\"hrv\":44,\"charge\":25}"]
        let result = ForgeNoteFigures.filter(note, sources: tools, effortOutOf100: true)
        XCTAssertEqual(result.struck, 2)
        XCTAssertEqual(result.text, "**You got only 1.7 hours recorded, with 3 disturbances.**\n\nBed by 22:30 tonight. Charge 25 is low.")
    }

    func testTheGuardKeepsWordsAndRoundsToTheWrittenPrecision() {
        XCTAssertEqual(ForgeNoteFigures.filter("A calm day. Rest when you can.", sources: [], effortOutOf100: true).struck, 0)
        XCTAssertEqual(ForgeNoteFigures.filter("HRV 44 ms.", sources: ["hrv 43.6"], effortOutOf100: true).struck, 0)
        XCTAssertEqual(ForgeNoteFigures.filter("HRV 43,6 ms.", sources: ["hrv 43.64"], effortOutOf100: true).struck, 0)
        XCTAssertEqual(ForgeNoteFigures.filter("Half an hour, 0.5 h.", sources: ["30 minutes"], effortOutOf100: true).struck, 0)
        XCTAssertEqual(ForgeNoteFigures.filter("Effort 13.2/21.", sources: ["13.2"], effortOutOf100: false).struck, 0)
        XCTAssertEqual(ForgeNoteFigures.filter("Sleep 7.5 h. Fine.", sources: ["asleep 300"], effortOutOf100: true).text, "Fine.")
        XCTAssertEqual(ForgeNoteFigures.filter("Charge 99.", sources: [], effortOutOf100: true).text, "")
    }

    // MARK: Blocks

    func testSmallEventsInARowShareOneCardAndLargeEntriesStandAlone() {
        func e(_ id: String, _ kind: ForgeTimeline.Entry.Kind) -> ForgeTimeline.Entry {
            ForgeTimeline.Entry(id: id, date: Date(timeIntervalSince1970: 0), kind: kind, title: "", detail: "",
                                value: nil, sourceId: nil)
        }
        let blocks = ForgeTimeline.blocks([e("w1", .workout), e("d1", .dayLog(.drink)), e("n", .coach(.afterWorkout)),
                                           e("k", .walks), e("m", .wake), e("x", .notice), e("y", .ecg)])
        XCTAssertEqual(blocks.map(\.id), ["rows-w1", "n", "rows-k", "m", "x", "rows-y"])
        if case .rows(let first) = blocks[0] { XCTAssertEqual(first.map(\.id), ["w1", "d1"]) } else { XCTFail() }
    }

    func testFollowUpsTravelWithTheirNote() {
        let t = Date(timeIntervalSince1970: 1_793_900_000)
        var input = ForgeTimeline.Input()
        input.coach = [.init(id: "n", date: t, text: "A calm morning. Keep it easy.", origin: .brief,
                             followUps: [.init(question: "Why?", answer: "Your night was short.")])]
        let entry = ForgeTimeline.build(input, now: t.addingTimeInterval(60), dayKey: { _ in "D" }).first?.entries.first
        XCTAssertEqual(entry?.followUps, [.init(question: "Why?", answer: "Your night was short.")])
    }

    // MARK: Journal causes behind a body-signal warning

    func testCausesWrittenByTheAppReadTheSameInEveryLanguage() {
        let found = JournalCause.present(in: [("Alkohol getrunken", JournalCause.alcohol.key),
                                              ("Gereist", JournalCause.travel.key)])
        XCTAssertEqual(found, [.alcohol, .travel])
    }

    /// The old fragment search read "ill" inside "still" and missed stress and travel altogether.
    func testImportedQuestionsAreReadByWholeEnglishWords() {
        XCTAssertEqual(JournalCause.present(in: [("Did you feel ill?", nil)]), [.sick])
        XCTAssertEqual(JournalCause.present(in: [("Sat still for an hour?", nil)]), [])
        XCTAssertEqual(JournalCause.present(in: [("Brille getragen?", nil)]), [])
        XCTAssertEqual(JournalCause.present(in: [("Feeling stressed?", nil)]), [.stress])
        XCTAssertEqual(JournalCause.present(in: [("Unter Stress gestanden?", nil)]), [.stress])
        XCTAssertEqual(JournalCause.present(in: [("Have any alcoholic drinks?", nil)]), [.alcohol])
        XCTAssertEqual(JournalCause.present(in: [("Genug Wasser getrunken?", nil)]), [])
    }

    func testANoteIsOutdatedOnlyWhenTodaysFiguresMoved() {
        let then = ForgeNoteBasis.make(day: "2026-11-03", charge: 30, asleepMinutes: 104)
        XCTAssertFalse(ForgeNoteBasis.isOutdated(stored: then, current: then))
        XCTAssertTrue(ForgeNoteBasis.isOutdated(stored: then,
                                                current: ForgeNoteBasis.make(day: "2026-11-03", charge: 25, asleepMinutes: 104)))
        XCTAssertFalse(ForgeNoteBasis.isOutdated(stored: then,
                                                 current: ForgeNoteBasis.make(day: "2026-11-04", charge: 53, asleepMinutes: 199)))
        XCTAssertFalse(ForgeNoteBasis.isOutdated(stored: nil, current: then))
    }
}
