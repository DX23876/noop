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

    func testATimedSessionJustPastItsTimeStaysWithinTheGraceWindow() {
        // Changed from the old "past time drops out": a session stays visible for `graceAfter` past its
        // time so the exact moment you're due/late isn't the moment the card vanishes. 07:30 is 30 min
        // before the 08:00 `now`, well inside the 120-min grace.
        let p = commitment(day: today, time: at("07:30", day: today))
        XCTAssertEqual(PlanTodayCard.next(from: [p], today: today, now: now)?.id, p.id)
    }

    func testATimedSessionBeyondTheGraceWindowIsNotShown() {
        // 05:30 is 150 min before 08:00 `now` — past the 120-min grace, so it finally drops out.
        let p = commitment(day: today, time: at("05:30", day: today))
        XCTAssertNil(PlanTodayCard.next(from: [p], today: today, now: now))
    }

    func testACompletedSessionIsNeverNextUp() {
        var p = commitment(day: today, time: at("18:00", day: today))
        p.status = .completed
        XCTAssertNil(PlanTodayCard.next(from: [p], today: today, now: now),
                     "a done session must not surface as 'next up'")
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

    // MARK: - Emphasis windows (colour + pulse near the session time)

    func testEmphasisIsNoneWellBeforeTheSession() {
        // 18:00 session, 08:00 now → 10h out, far outside the 30-min approach lead.
        let p = commitment(day: today, time: at("18:00", day: today))
        XCTAssertEqual(PlanTodayCard.emphasis(for: p, now: now), .none)
    }

    func testEmphasisIsApproachingInsideTheLeadWindow() {
        // Session at 08:20, now 08:00 → 20 min out, inside the 30-min lead.
        let p = commitment(day: today, time: at("08:20", day: today))
        XCTAssertEqual(PlanTodayCard.emphasis(for: p, now: now), .approaching)
    }

    func testEmphasisIsDueFromTheTimeUntilGraceEnds() {
        // Session at 07:00, now 08:00 → 60 min past, inside the 120-min grace.
        let p = commitment(day: today, time: at("07:00", day: today))
        XCTAssertEqual(PlanTodayCard.emphasis(for: p, now: now), .due)
    }

    func testEmphasisReturnsToNoneAfterTheGraceWindow() {
        // Session at 05:30, now 08:00 → 150 min past, beyond the 120-min grace.
        let p = commitment(day: today, time: at("05:30", day: today))
        XCTAssertEqual(PlanTodayCard.emphasis(for: p, now: now), .none)
    }

    func testAnUntimedCommitmentIsNeverEmphasised() {
        // No time → nothing to count to, so no colour/pulse even though the card shows.
        let p = commitment(day: today, time: nil)
        XCTAssertEqual(PlanTodayCard.emphasis(for: p, now: now), .none)
    }
}
