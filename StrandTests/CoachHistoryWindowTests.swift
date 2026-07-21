import XCTest
@testable import Strand

/// The history window: a per-model TOKEN budget, replacing the flat 10-message count that treated a
/// 2 048-token local Ollama model and a 200 000-token Claude identically.
///
/// The two invariants that matter are the ones a naive budget breaks: the window must never fall below
/// what the old build sent (no provider gets *less* context out of this change), and the first user turn
/// — the one carrying the data context — must survive however hard the middle is cut.
@MainActor
final class CoachHistoryWindowTests: XCTestCase {

    private func turns(_ count: Int, chars: Int = 40) -> [ChatMessage] {
        (0..<count).map { i in
            ChatMessage(role: i.isMultiple(of: 2) ? .user : .assistant,
                        text: String(repeating: "x", count: chars) + " #\(i)")
        }
    }

    // MARK: - The floor: never worse than the old flat window

    func testShortConversationIsSentWhole() {
        let all = turns(6)
        XCTAssertEqual(AICoachEngine.windowedMessages(all, budgetTokens: 12_000).count, 6)
    }

    func testTinyBudgetStillSendsTheFloor() {
        let all = turns(40)
        let window = AICoachEngine.windowedMessages(all, budgetTokens: 1)

        XCTAssertGreaterThanOrEqual(window.count, CoachHistoryBudget.minMessages,
                                    "a budget too small to fit the floor must still send the floor — "
                                    + "sending less than the previous flat window would be a regression")
    }

    func testFloorMatchesTheOldFlatWindow() {
        XCTAssertEqual(CoachHistoryBudget.minMessages, 10,
                       "the floor IS the old maxHistoryMessages; changing it changes small-model "
                       + "behaviour and Android parity")
    }

    // MARK: - The budget actually moves the window

    func testLargeBudgetKeepsMoreThanTheFloor() {
        let all = turns(40, chars: 40)   // ~11 tokens each
        let window = AICoachEngine.windowedMessages(all, budgetTokens: 12_000)

        XCTAssertEqual(window.count, 40, "40 short turns fit comfortably in 12k tokens")
    }

    func testSmallBudgetCutsBackToTheFloor() {
        let all = turns(40, chars: 4_000)   // ~1 000 tokens each
        let window = AICoachEngine.windowedMessages(all, budgetTokens: 1_200)

        // The floor is the RECENT window; the anchored first user turn rides on top of it, exactly as
        // the old flat implementation did (`[firstUser] + suffix(10)`).
        XCTAssertEqual(window.count, CoachHistoryBudget.minMessages + 1,
                       "long turns against a local-model budget collapse to the floor plus the anchor")
        XCTAssertEqual(window.first?.text, all.first?.text, "…and the anchor is the first user turn")
    }

    func testWindowGrowsMonotonicallyWithBudget() {
        let all = turns(60, chars: 400)   // ~101 tokens each
        let small = AICoachEngine.windowedMessages(all, budgetTokens: 1_200).count
        let large = AICoachEngine.windowedMessages(all, budgetTokens: 12_000).count

        XCTAssertGreaterThan(large, small, "a bigger window is the entire point of the change")
    }

    // MARK: - The first user turn carries the data context and must survive

    func testFirstUserTurnIsAlwaysKept() {
        var all = turns(40, chars: 4_000)
        all[0] = ChatMessage(role: .user, text: "THE ORIGINAL QUESTION")
        let window = AICoachEngine.windowedMessages(all, budgetTokens: 1_200)

        XCTAssertEqual(window.first?.text, "THE ORIGINAL QUESTION",
                       "the metrics context rides the first user turn; dropping it strips the request")
        XCTAssertTrue(window.contains { $0.text.contains("#39") }, "the newest turn is kept too")
    }

    func testNoDuplicateWhenFirstUserTurnIsAlreadyInTheWindow() {
        var all = turns(12, chars: 4_000)
        all[0] = ChatMessage(role: .assistant, text: "greeting")
        all[1] = ChatMessage(role: .user, text: "THE ORIGINAL QUESTION")
        let window = AICoachEngine.windowedMessages(all, budgetTokens: 1_200)

        XCTAssertEqual(window.filter { $0.text == "THE ORIGINAL QUESTION" }.count, 1,
                       "prepending a turn the recent window already covers would send it twice")
    }

    func testConversationWithNoUserTurnIsPassedThrough() {
        let briefOnly = (0..<20).map { ChatMessage(role: .assistant, text: "brief \($0)") }
        XCTAssertEqual(AICoachEngine.windowedMessages(briefOnly, budgetTokens: 1).count, 20,
                       "no user turn to anchor on — leave it alone rather than cutting blind")
    }

    // MARK: - Budget selection per provider/model

    func testCloudProvidersAreSpacious() {
        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .anthropic, model: "claude-sonnet-4-6"),
                       CoachHistoryBudget.spaciousTokens)
        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .gemini, model: "gemini-pro-latest"),
                       CoachHistoryBudget.spaciousTokens)
    }

    func testUnknownLocalModelIsConservative() {
        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .custom, model: "some-local-7b"),
                       CoachHistoryBudget.conservativeTokens,
                       "guessing large on a small local model risks a hard context overflow")
    }

    func testKnownLargeModelBehindCustomOrOpenRouterIsSpacious() {
        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .openRouter,
                                                 model: "anthropic/claude-sonnet-4.6"),
                       CoachHistoryBudget.spaciousTokens,
                       "OpenRouter ids are vendor/slug — the family has to be read from the id")
        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .custom, model: "gemini-flash-latest"),
                       CoachHistoryBudget.spaciousTokens)
    }

    func testEmptyModelIdIsConservative() {
        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .custom, model: ""),
                       CoachHistoryBudget.conservativeTokens)
    }

    // MARK: - The estimate

    func testEstimateIsCharactersOverFourRoundedUp() {
        XCTAssertEqual(CoachHistoryBudget.estimateTokens(""), 0)
        XCTAssertEqual(CoachHistoryBudget.estimateTokens("abcd"), 1)
        XCTAssertEqual(CoachHistoryBudget.estimateTokens("abcde"), 2, "partial tokens round up, so the "
                       + "estimate errs toward under-filling the window")
    }
}
