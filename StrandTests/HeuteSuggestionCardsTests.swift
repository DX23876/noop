import XCTest
@testable import Strand

/// Pins the real-source mapping for Heute's suggestion cards (D-package 2): pending `PlanProposal`s →
/// `NotificationCardItem`s, gated by activity status and local dismissals, plus the dismissed-id store's
/// roundtrip + pruning. Pure value logic + a UserDefaults-backed store, database-free — mirrors
/// `ActivityStatusTests`.
final class HeuteSuggestionCardsTests: XCTestCase {

    private func proposal(_ id: UUID = UUID(), day: String = "2026-07-24",
                          sport: String = "Zone 2 ride", intent: PlanProposal.Intent = .moderate,
                          rationale: String = "", status: PlanProposal.Status = .proposed) -> PlanProposal {
        PlanProposal(id: id, day: day, sport: sport, intent: intent, rationale: rationale, status: status)
    }

    // MARK: - cards(pending:dayKey:status:dismissed:)

    func testActiveStatusSurfacesPendingForTheDay() {
        let cards = HeuteSuggestionCards.cards(pending: [proposal()], dayKey: "2026-07-24",
                                               status: .active, dismissed: [])
        XCTAssertEqual(cards.count, 1)
    }

    func testExceptionStatusSuppressesAllCards() {
        // Sick / Injured / On break pause training suggestions — the whole point of the flag.
        for state in [ActivityStatus.State.sick, .injured, .onBreak] {
            let status = ActivityStatus(state: state, validUntil: nil, setAt: Date())
            let cards = HeuteSuggestionCards.cards(pending: [proposal(), proposal()],
                                                   dayKey: "2026-07-24", status: status, dismissed: [])
            XCTAssertTrue(cards.isEmpty, "\(state) should suppress cards")
        }
    }

    func testOnlyProposalsForTheSelectedDay() {
        let today = proposal(day: "2026-07-24")
        let other = proposal(day: "2026-07-23")
        let cards = HeuteSuggestionCards.cards(pending: [today, other], dayKey: "2026-07-24",
                                               status: .active, dismissed: [])
        XCTAssertEqual(cards.map(\.id), [today.id.uuidString])
    }

    func testDismissedProposalsAreFilteredOut() {
        let a = proposal(), b = proposal()
        let cards = HeuteSuggestionCards.cards(pending: [a, b], dayKey: "2026-07-24",
                                               status: .active, dismissed: [a.id.uuidString])
        XCTAssertEqual(cards.map(\.id), [b.id.uuidString])
    }

    func testPendingOrderIsPreserved() {
        let a = proposal(), b = proposal(), c = proposal()
        let cards = HeuteSuggestionCards.cards(pending: [a, b, c], dayKey: "2026-07-24",
                                               status: .active, dismissed: [])
        XCTAssertEqual(cards.map(\.id), [a, b, c].map { $0.id.uuidString })
    }

    // MARK: - text(for:)

    func testTextUsesRationaleWhenPresent() {
        let p = proposal(sport: "CrossFit", rationale: "Recovery is high, push a little.")
        XCTAssertEqual(HeuteSuggestionCards.text(for: p), "CrossFit — Recovery is high, push a little.")
    }

    func testTextFallsBackToIntentAndSportWhenNoRationale() {
        let p = proposal(sport: "Easy jog", intent: .easy, rationale: "   ")
        // Intent label is localized; the source locale (en) is "Easy".
        XCTAssertEqual(HeuteSuggestionCards.text(for: p), "Easy · Easy jog")
    }

    // MARK: - DismissedSuggestionsStore

    func testStoreRoundTrips() {
        let name = "test.dismissed.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        DismissedSuggestionsStore.save(["a", "b"], to: d)
        XCTAssertEqual(DismissedSuggestionsStore.load(from: d), ["a", "b"])
    }

    func testStorePrunesToLiveIDsOnLoad() {
        let name = "test.dismissed.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        DismissedSuggestionsStore.save(["a", "b", "stale"], to: d)
        // Only "a"/"b" are still pending; "stale" is dropped and the pruned set is written back.
        let loaded = DismissedSuggestionsStore.load(from: d, keepingOnly: ["a", "b"])
        XCTAssertEqual(loaded, ["a", "b"])
        XCTAssertEqual(Set(d.stringArray(forKey: DismissedSuggestionsStore.key) ?? []), ["a", "b"])
    }

    func testStoreWithoutLiveIDsReturnsStoredUnpruned() {
        let name = "test.dismissed.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        DismissedSuggestionsStore.save(["x"], to: d)
        XCTAssertEqual(DismissedSuggestionsStore.load(from: d), ["x"])
    }
}
