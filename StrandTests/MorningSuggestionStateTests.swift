import XCTest
@testable import Strand

/// `MorningSuggestionState.resolve` decides what the Today morning card shows. Pure — no SwiftUI.
final class MorningSuggestionStateTests: XCTestCase {

    private let today = "2026-07-16"

    private func pending(day: String, sport: String = "Zone 2 ride") -> PlanProposal {
        PlanProposal(day: day, sport: sport, intent: .easy)  // .proposed
    }

    private func resolve(
        morningOn: Bool = true, configured: Bool = true, consent: Bool = true, toolsActive: Bool = true,
        sending: Bool = false, pending: [PlanProposal] = [], unsettledWake: Int? = nil
    ) -> MorningSuggestionState {
        MorningSuggestionState.resolve(
            morningOn: morningOn, configured: configured, consent: consent, toolsActive: toolsActive,
            sending: sending, pending: pending, today: today, unsettledWake: unsettledWake)
    }

    // MARK: - The unsettled night, which is not a coach question (2026-11-18)

    /// The fault this fixes: the verdict sat behind every coach gate, so on Android — where this card is
    /// the state's only home — a wearer without a provider was never told that today's recovery was
    /// computed on a night the strap had not finished handing over.
    func testTheUnsettledNightShowsWithoutACoach() {
        XCTAssertEqual(resolve(morningOn: false, configured: false, consent: false, toolsActive: false,
                               unsettledWake: 1_763_446_320),
                       .confirmWake(detectedWake: 1_763_446_320))
    }

    /// A proposal is advice built on last night's numbers. While those are still moving, saying so comes
    /// first.
    func testTheUnsettledNightWinsOverAWaitingProposal() {
        XCTAssertEqual(resolve(pending: [pending(day: today)], unsettledWake: 42),
                       .confirmWake(detectedWake: 42))
    }

    // MARK: - Hidden gates

    /// The opt-in only gates the PROACTIVE morning nudge (`maybeGenerate()`'s own guard) — it must never
    /// hide a proposal that already exists, e.g. one the coach recorded because the user stated a plain-
    /// language training intent in an ordinary chat message (#R-auto-session). Regression test for the
    /// bug this package fixes: a fresh chat-recorded proposal used to be invisible on Today unless the
    /// separate auto-suggestion toggle was also on.
    func testAPendingProposalShowsRegardlessOfTheOptIn() {
        let p = pending(day: today)
        XCTAssertEqual(resolve(morningOn: false, pending: [p]), .waiting(p))
    }

    func testHiddenWithTheOptInOffAndNothingPending() {
        XCTAssertEqual(resolve(morningOn: false, pending: []), .hidden)
    }

    func testHiddenWithoutAKeyOrConsent() {
        XCTAssertEqual(resolve(configured: false, pending: [pending(day: today)]), .hidden)
        XCTAssertEqual(resolve(consent: false, pending: [pending(day: today)]), .hidden)
    }

    /// The provider can't run tools, so no proposal could ever exist — promising a card would be a lie.
    func testHiddenWhenTheProviderCannotRunTools() {
        XCTAssertEqual(resolve(toolsActive: false, pending: [pending(day: today)]), .hidden)
    }

    func testHiddenWhenNothingIsPendingAndNotSending() {
        XCTAssertEqual(resolve(), .hidden)
    }

    // MARK: - Waiting

    func testWaitingSurfacesTodaysPendingProposal() {
        let p = pending(day: today)
        XCTAssertEqual(resolve(pending: [p]), .waiting(p))
    }

    func testATomorrowProposalDoesNotShowOnTodaysCard() {
        XCTAssertEqual(resolve(pending: [pending(day: "2026-07-17")]), .hidden)
    }

    /// An existing proposal wins over the spinner — mid-send, the outcome is already on screen.
    func testAPendingProposalWinsOverTheGeneratingState() {
        let p = pending(day: today)
        XCTAssertEqual(resolve(sending: true, pending: [p]), .waiting(p))
    }

    // MARK: - Generating

    func testGeneratingOnlyWhileSendingAndOptedIn() {
        XCTAssertEqual(resolve(sending: true), .generating)
        // Sending but opted out ⇒ still hidden (the guard runs first).
        XCTAssertEqual(resolve(morningOn: false, sending: true), .hidden)
    }

    // MARK: - Hand-off

    /// Once the proposal is accepted it leaves `pending`, so the card hides and PlanTodayCard shows the
    /// answer — no double row on Today.
    func testAnAcceptedProposalLeavesTheCard() {
        // An accepted session is no longer in `pending`, so from this card's input it's simply gone.
        XCTAssertEqual(resolve(pending: []), .hidden)
    }
}
