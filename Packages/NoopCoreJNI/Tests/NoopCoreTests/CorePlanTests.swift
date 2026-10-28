import Foundation
import XCTest
import StrandCore
import StrandAnalytics
@testable import NoopCore

/// The plan book's wording on Android is `CoachPlanView`'s: relative day names and neutral status lines.
/// Only the pure wording is tested here; the store writes the wearer's real plan file.
@MainActor
final class CorePlanTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!

    private func day(_ offset: Int) -> String {
        StoreReader.localDayKey(now.addingTimeInterval(Double(offset) * 86_400))
    }

    func testRelativeDayNames() {
        XCTAssertEqual(CorePlan.dayLabel(day(0), now: now), "Today")
        XCTAssertEqual(CorePlan.dayLabel(day(1), now: now), "Tomorrow")
        XCTAssertEqual(CorePlan.dayLabel(day(-1), now: now), "Yesterday")
        XCTAssertEqual(CorePlan.dayLabel("not a day", now: now), "not a day")
    }

    func testStatusLinesStayNeutral() {
        var p = PlanProposal(day: day(-2), sport: "Run", intent: .easy, status: .skipped, skipReason: .pain)
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "didn't happen — Pain")
        p.status = .completed
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "completed — effect not rated")
        p.effectFeedback = .helpful
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "completed — Helpful")
        p.status = .declined
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "you passed on this one")
        p.status = .rescheduled
        p.rescheduledFrom = day(-1)
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "moved from Yesterday")
    }

    /// Only an agreed session with a time still ahead reminds; a suggestion, a past time or a done one never does.
    func testRemindersOnlyForAgreedTimedSessionsAhead() {
        let ahead = now.addingTimeInterval(3600)
        let agreed = PlanProposal(day: day(1), time: ahead, sport: "Run", intent: .easy, status: .accepted)
        let past = PlanProposal(day: day(1), time: now.addingTimeInterval(-60), sport: "Run", intent: .easy, status: .accepted)
        let done = PlanProposal(day: day(1), time: ahead, sport: "Run", intent: .easy, status: .completed)
        let waiting = PlanProposal(day: day(1), time: ahead, sport: "Run", intent: .easy, status: .proposed)
        let untimed = PlanProposal(day: day(1), sport: "Ride", intent: .easy, status: .accepted)
        let out = CorePlan.reminders([agreed, past, done, waiting, untimed], scale: .hundred, now: now)
        XCTAssertEqual(out.map(\.id), [agreed.id.uuidString])
        XCTAssertEqual(out.first?.title, "Time for your planned session")
        XCTAssertEqual(out.first?.body, agreed.summary(effortScale: .hundred))
    }
}

/// The Lab's training-based VO₂max reaches Training Load with what it rests on, as `exerciseVO2maxRow` reads it.
final class CoreExerciseVO2maxTests: XCTestCase {
    func testNoSessionStillCarriesTheValidationRule() {
        let out = CoreTrainingLoad.exerciseOutput([], used: 0, onFoot: 3, apple: [])
        XCTAssertNil(out.value)
        XCTAssertNil(out.mondayKey)
        XCTAssertEqual(out.sessionsOnFoot, 3)
        XCTAssertEqual(out.pairs, 0)
        XCTAssertEqual(out.pairsNeeded, ExerciseVO2max.validationMinimumPairs)
        XCTAssertFalse(out.passes)
    }
}

/// The morning suggestion on Android resolves by iOS's `MorningSuggestionState` and words its card the same way.
@MainActor
final class CoreMorningSuggestionTests: XCTestCase {
    private let today = "2026-10-28"

    func testWaitingProposalShowsEvenWithTheSwitchOff() {
        let p = PlanProposal(day: today, sport: "Run", intent: .rest, rationale: "Low charge")
        let state = MorningSuggestionState.resolve(morningOn: false, configured: true, consent: true, toolsActive: true,
                                                   sending: false, pending: [p], today: today)
        let card = CoreCoach.card(state, on: false, scale: .hundred)
        XCTAssertEqual(card.kind, "waiting")
        XCTAssertEqual(card.id, p.id.uuidString)
        XCTAssertEqual(card.title, "Rest day suggested")
        XCTAssertEqual(card.rationale, "Low charge")
    }

    func testUnsettledNightAsksAboutTheWakeOnlyWhenSwitchedOn() {
        let off = MorningSuggestionState.resolve(morningOn: false, configured: true, consent: true, toolsActive: true,
                                                 sending: false, pending: [], today: today, unsettledWake: 1_800_000_000)
        XCTAssertEqual(CoreCoach.card(off, on: false, scale: .hundred).kind, "hidden")
        let on = MorningSuggestionState.resolve(morningOn: true, configured: true, consent: true, toolsActive: true,
                                                sending: false, pending: [], today: today, unsettledWake: 1_800_000_000)
        let card = CoreCoach.card(on, on: true, scale: .hundred)
        XCTAssertEqual(card.kind, "confirmWake")
        XCTAssertEqual(card.wake, 1_800_000_000)
        XCTAssertTrue(card.wakeText?.contains("%@") == true)
    }

    func testNoProviderHidesEverything() {
        let p = PlanProposal(day: today, sport: "Run", intent: .easy)
        let state = MorningSuggestionState.resolve(morningOn: true, configured: false, consent: true, toolsActive: true,
                                                   sending: true, pending: [p], today: today)
        XCTAssertEqual(CoreCoach.card(state, on: true, scale: .hundred).kind, "hidden")
    }
}
