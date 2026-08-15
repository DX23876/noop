import XCTest
@testable import Strand
import StrandAnalytics

/// The second half of the wake-time report: after correcting the sleep by hand, the WRONG brief used to
/// stand for the rest of the day, because the day had already been stamped.
///
/// `CoachBriefStamp` owns that bookkeeping now; these pin its rules. The suite writes to a scoped
/// UserDefaults so a test run never rewrites a real install's brief history.
@MainActor
final class CoachBriefStampTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CoachBriefStampTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var today: String { Repository.logicalDayKey(Date()) }

    func testStampAndRead() {
        XCTAssertNil(CoachBriefStamp.lastBriefDay(defaults: defaults))
        CoachBriefStamp.stamp(day: today, defaults: defaults)
        XCTAssertEqual(CoachBriefStamp.lastBriefDay(defaults: defaults), today)
    }

    /// Correcting TODAY's night drops the stamp and marks the brief stale — the two together are what
    /// let the next open write a brief against the corrected recovery.
    func testCorrectingTonightInvalidatesTheBrief() {
        CoachBriefStamp.stamp(day: today, defaults: defaults)
        let wokeThisMorning = Int(Date().timeIntervalSince1970) - 3600

        XCTAssertTrue(CoachBriefStamp.invalidateAfterSleepCorrection(wakeTs: wokeThisMorning, defaults: defaults))
        XCTAssertNil(CoachBriefStamp.lastBriefDay(defaults: defaults))
        XCTAssertTrue(CoachBriefStamp.isStale(today: today, defaults: defaults))
    }

    /// Fixing a night from last week changes that week's history, not this morning's plan. Re-briefing
    /// for it would be noise, so the stamp survives.
    func testCorrectingAnOldNightLeavesTodaysBriefAlone() {
        CoachBriefStamp.stamp(day: today, defaults: defaults)
        let lastWeek = Int(Date().timeIntervalSince1970) - 7 * 86_400

        XCTAssertFalse(CoachBriefStamp.invalidateAfterSleepCorrection(wakeTs: lastWeek, defaults: defaults))
        XCTAssertEqual(CoachBriefStamp.lastBriefDay(defaults: defaults), today)
        XCTAssertFalse(CoachBriefStamp.isStale(today: today, defaults: defaults))
    }

    func testClearStale() {
        CoachBriefStamp.invalidateAfterSleepCorrection(
            wakeTs: Int(Date().timeIntervalSince1970) - 3600, defaults: defaults)
        XCTAssertTrue(CoachBriefStamp.isStale(today: today, defaults: defaults))
        CoachBriefStamp.clearStale(defaults: defaults)
        XCTAssertFalse(CoachBriefStamp.isStale(today: today, defaults: defaults))
    }

    /// The wearer's word outranks the heuristic for the rest of the day — the gate exists to protect
    /// them from a wrong number, not to make them argue with one.
    func testConfirmingTheWakeTimeIsRememberedForTheDay() {
        XCTAssertFalse(CoachBriefStamp.wakeConfirmed(today: today, defaults: defaults))
        CoachBriefStamp.confirmWake(day: today, defaults: defaults)
        XCTAssertTrue(CoachBriefStamp.wakeConfirmed(today: today, defaults: defaults))
        XCTAssertFalse(CoachBriefStamp.wakeConfirmed(today: "1999-01-01", defaults: defaults),
                       "a confirmation is for ONE day, not forever")
    }

    // MARK: - The caveat wording

    /// A doubtful night has to reach every path that quotes a Charge, and say something the model can
    /// act on rather than a vague hedge.
    func testCaveatsNameTheProblemAndTheFix() throws {
        XCTAssertNil(AICoachEngine.wakeTimeCaveat(.settled))

        let awaiting = try XCTUnwrap(AICoachEngine.wakeTimeCaveat(.awaitingSync))
        XCTAssertTrue(awaiting.contains("CAUTION"), awaiting)
        XCTAssertTrue(awaiting.lowercased().contains("sync"), awaiting)

        let early = try XCTUnwrap(AICoachEngine.wakeTimeCaveat(.wakeLooksEarly))
        XCTAssertTrue(early.contains("CAUTION"), early)
        XCTAssertTrue(early.contains("Sleep"), "it should point at the screen that fixes it: \(early)")
    }

    // MARK: - The morning card

    /// With nothing to confirm the card behaves exactly as before.
    func testCardHidesWhenTheNightIsFine() {
        XCTAssertEqual(
            MorningSuggestionState.resolve(morningOn: true, configured: true, consent: true,
                                           toolsActive: true, sending: false, pending: [], today: today,
                                           unsettledWake: nil),
            .hidden)
    }

    /// A withheld brief shows the confirmation instead of nothing — silence alone reads as the coach
    /// being broken.
    func testCardAsksAboutAnUnsettledNight() {
        let wake = 1_700_000_000
        XCTAssertEqual(
            MorningSuggestionState.resolve(morningOn: true, configured: true, consent: true,
                                           toolsActive: true, sending: false, pending: [], today: today,
                                           unsettledWake: wake),
            .confirmWake(detectedWake: wake))
    }

    /// A proposal already waiting on the user is the more useful thing to show, so it still wins.
    func testAWaitingProposalOutranksTheConfirmation() {
        let p = PlanProposal(day: today, sport: "Ride", intent: .easy)
        XCTAssertEqual(
            MorningSuggestionState.resolve(morningOn: true, configured: true, consent: true,
                                           toolsActive: true, sending: false, pending: [p], today: today,
                                           unsettledWake: 1_700_000_000),
            .waiting(p))
    }

    /// Someone who never opted into the proactive brief should not be handed a chore about it either.
    func testNoConfirmationWithoutTheMorningOptIn() {
        XCTAssertEqual(
            MorningSuggestionState.resolve(morningOn: false, configured: true, consent: true,
                                           toolsActive: true, sending: false, pending: [], today: today,
                                           unsettledWake: 1_700_000_000),
            .hidden)
    }
}
