import XCTest
@testable import Strand

/// `PlanTodayCard.next` decides the single committed session Today surfaces. The regression it exists
/// for (W4): accepting a proposal records NO time (accept is a yes, not a scheduling act), and the card
/// used to require `time != nil` — so an accepted session vanished from Today until the user separately
/// opened PlanTimeSheet. An untimed commitment for TODAY must show.
final class PlanTodayCardSelectionTests: XCTestCase {

    private let today = "2026-07-16"
    private let tomorrow = "2026-07-17"
    // A fixed "now" at 08:00 on `today`, so "still ahead" comparisons are deterministic.
    private var now: Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = .current
        return f.date(from: "2026-07-16 08:00")!
    }

    private func at(_ hhmm: String, day: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = .current
        return f.date(from: "\(day) \(hhmm)")!
    }

    private func commitment(day: String, time: Date?, sport: String = "Zone 2 ride") -> PlanProposal {
        PlanProposal(day: day, time: time, sport: sport, intent: .easy,
                     status: .accepted, source: .userCreated)
    }

    // MARK: - The regression

    func testAnUntimedCommitmentForTodayIsShown() {
        let p = commitment(day: today, time: nil)
        XCTAssertEqual(PlanTodayCard.next(from: [p], today: today, now: now)?.id, p.id,
                       "an accepted-but-untimed session for today must not vanish from Today")
    }

    func testAnUntimedCommitmentForTomorrowIsNotShown() {
        let p = commitment(day: tomorrow, time: nil)
        XCTAssertNil(PlanTodayCard.next(from: [p], today: today, now: now),
                     "an untimed session two days out isn't 'next up'")
    }

    // MARK: - Timed still works, and wins

    func testATimedSessionStillAheadTodayIsShown() {
        let p = commitment(day: today, time: at("18:00", day: today))
        XCTAssertEqual(PlanTodayCard.next(from: [p], today: today, now: now)?.id, p.id)
    }

    func testATimedSessionTodayWinsOverAnUntimedOne() {
        let timed = commitment(day: today, time: at("18:00", day: today), sport: "Evening ride")
        let untimed = commitment(day: today, time: nil, sport: "Mobility")
        // A real appointment sorts before an untimed session (`time ?? .distantFuture`).
        XCTAssertEqual(PlanTodayCard.next(from: [untimed, timed], today: today, now: now)?.id, timed.id)
    }

    func testATimedSessionWhoseTimeHasPassedIsNotShown() {
        // Behaviour deliberately preserved from before W4: a past time drops out (the adjacent "can't
        // tick off this morning's session" bug is out of scope, flagged in the plan).
        let p = commitment(day: today, time: at("06:00", day: today))
        XCTAssertNil(PlanTodayCard.next(from: [p], today: today, now: now))
    }

    // MARK: - Consent nail: the answer card must not render the question

    func testAProposalIsNeverShownAsACommitment() {
        // A .proposed row for today (with or without a time) is the QUESTION — MorningSuggestionCard's
        // job, not this card's. It must never surface here.
        let untimed = PlanProposal(day: today, sport: "Zone 2 ride", intent: .easy)  // .proposed
        let timed = PlanProposal(day: today, time: at("18:00", day: today), sport: "Zone 2 ride",
                                 intent: .easy)  // .proposed
        XCTAssertNil(PlanTodayCard.next(from: [untimed], today: today, now: now))
        XCTAssertNil(PlanTodayCard.next(from: [timed], today: today, now: now))
    }

    func testADeclinedSessionIsNotShown() {
        var p = commitment(day: today, time: nil)
        p.status = .declined
        XCTAssertNil(PlanTodayCard.next(from: [p], today: today, now: now))
    }

    func testNothingCommittedShowsNothing() {
        XCTAssertNil(PlanTodayCard.next(from: [], today: today, now: now))
    }
}
