import XCTest
@testable import Strand

/// The chat's own tools: searching the history, pinning a thread, exporting one, and taking a question
/// back to edit it. Pure model/engine behaviour — the SwiftUI wiring isn't testable here, the rules are.
@MainActor
final class CoachChatToolsTests: XCTestCase {

    private func convo(_ title: String,
                       asked: [String] = [],
                       replied: [String] = [],
                       summary: String? = nil,
                       pinned: Bool = false,
                       archived: Bool = false) -> CoachConversation {
        var messages: [ChatMessage] = []
        for (i, q) in asked.enumerated() {
            messages.append(ChatMessage(role: .user, text: q))
            if i < replied.count { messages.append(ChatMessage(role: .assistant, text: replied[i])) }
        }
        return CoachConversation(title: title, messages: messages, summary: summary,
                                 archived: archived, pinned: pinned)
    }

    // MARK: - History search

    /// Substring, not whole-word: someone typing into a search field expects "schl" to find "Schlaf"
    /// while they are still typing. The model-facing `search_past_conversations` matches whole tokens
    /// instead, because it searches by topic — the two are deliberately different.
    func testSearchMatchesPartialWords() {
        let c = convo("Schlafqualität", asked: ["Wie verbessere ich meinen Schlaf?"])
        XCTAssertTrue(c.matches(search: "schl"))
        XCTAssertTrue(c.matches(search: "SCHLAF"), "case-insensitive")
    }

    func testSearchIgnoresDiacritics() {
        let c = convo("Trainingsgröße", asked: ["Frage"])
        XCTAssertTrue(c.matches(search: "grosse"), "\"grosse\" must find \"größe\"")
    }

    func testSearchLooksAtTitleSummaryAndMessages() {
        XCTAssertTrue(convo("A", asked: ["nothing"], summary: "about cycling").matches(search: "cycling"))
        XCTAssertTrue(convo("cycling", asked: ["nothing"]).matches(search: "cycling"))
        XCTAssertTrue(convo("A", asked: ["about cycling"]).matches(search: "cycling"))
    }

    func testEmptySearchMatchesEverything() {
        XCTAssertTrue(convo("A", asked: ["x"]).matches(search: ""))
        XCTAssertTrue(convo("A", asked: ["x"]).matches(search: "   "),
                      "whitespace is not a query — it must not empty the list")
    }

    func testNonMatchingSearchIsFalse() {
        XCTAssertFalse(convo("Schlaf", asked: ["Frage"]).matches(search: "Radfahren"))
    }

    // MARK: - Pinning survives the conversation cap

    /// The cap drops the OLDEST threads, which is exactly the one someone pins: the plan they keep
    /// returning to, months old. Pinning something and having the app silently bin it later would defeat
    /// the point of the feature.
    func testPinnedThreadsSurviveTheCap() {
        let cap = CoachConversationStore.maxConversations
        var all = (0..<cap).map { convo("recent \($0)") }
        all.append(convo("pinned but ancient", pinned: true))   // oldest, at the end

        let kept = CoachConversationStore.applyCap(all)

        XCTAssertEqual(kept.count, cap)
        XCTAssertTrue(kept.contains { $0.title == "pinned but ancient" })
        XCTAssertFalse(kept.contains { $0.title == "recent \(cap - 1)" },
                       "the cap now falls on the oldest UNPINNED thread instead")
    }

    func testCapIsANoOpBelowTheLimit() {
        let few = (0..<5).map { convo("c\($0)") }
        XCTAssertEqual(CoachConversationStore.applyCap(few).count, 5)
    }

    func testCapPreservesOrder() {
        let all = (0..<(CoachConversationStore.maxConversations + 5)).map { convo("c\($0)") }
        let kept = CoachConversationStore.applyCap(all)
        XCTAssertEqual(kept.map(\.title), Array(all.prefix(kept.count)).map(\.title),
                       "most-recent-first ordering must survive the cap")
    }

    func testPinnedIsBackCompatibleWithOlderJSON() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Old","createdAt":700000000,
         "updatedAt":700000000,"messages":[],"charts":{}}
        """.data(using: .utf8)!
        XCTAssertFalse(try JSONDecoder().decode(CoachConversation.self, from: legacy).pinned)
    }

    // MARK: - Markdown export

    func testExportNamesBothSpeakers() {
        let c = convo("Recovery", asked: ["Warum ist meine Charge niedrig?"],
                      replied: ["Deine HRV liegt unter Baseline."])
        let md = c.markdownExport(coachName: "Svea")

        XCTAssertTrue(md.contains("# Recovery"))
        XCTAssertTrue(md.contains("**You**: Warum ist meine Charge niedrig?"))
        XCTAssertTrue(md.contains("**Svea**: Deine HRV liegt unter Baseline."))
    }

    func testExportUsesTheConfiguredCoachName() {
        let md = convo("X", asked: ["q"], replied: ["a"]).markdownExport(coachName: "Marv")
        XCTAssertTrue(md.contains("**Marv**"), "the export should read like the coach the user set up")
    }

    func testUntitledConversationStillGetsAHeading() {
        XCTAssertTrue(convo("", asked: ["q"]).markdownExport(coachName: "Svea")
            .contains("# Coach conversation"))
    }

    /// An empty assistant turn is a chart HOST, not a blank reply. Exporting it as an empty line would
    /// read as the coach saying nothing.
    func testChartHostIsNamedRatherThanExportedBlank() {
        let hostID = UUID()
        var c = CoachConversation(title: "Trend",
                                  messages: [ChatMessage(role: .user, text: "Zeig mir HRV"),
                                             ChatMessage(id: hostID, role: .assistant, text: "")])
        c.charts[hostID.uuidString] = CoachChartSnapshot(
            CoachChartArtifact(title: "HRV", points: [], valueRange: 0...100, kind: .hrv))
        let md = c.markdownExport(coachName: "Svea")

        XCTAssertTrue(md.contains("*[chart]*"))
    }

    // MARK: - Reclaiming a question to edit it

    private func makeEngine() -> AICoachEngine {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-chattools-\(UUID().uuidString)"))
        engine.newConversation()
        return engine
    }

    func testReclaimReturnsTheQuestionAndDropsTheExchange() {
        let engine = makeEngine()
        engine.messages = [ChatMessage(role: .user, text: "Wie war meine Wochee?"),
                           ChatMessage(role: .assistant, text: "Solide.")]

        XCTAssertEqual(engine.reclaimLastQuestion(), "Wie war meine Wochee?")
        XCTAssertTrue(engine.messages.isEmpty,
                      "the mistyped question must leave the transcript — otherwise it keeps feeding the "
                      + "history window on every later turn")
    }

    func testReclaimKeepsEarlierExchanges() {
        let engine = makeEngine()
        engine.messages = [ChatMessage(role: .user, text: "erste Frage"),
                           ChatMessage(role: .assistant, text: "erste Antwort"),
                           ChatMessage(role: .user, text: "zweite Frage"),
                           ChatMessage(role: .assistant, text: "zweite Antwort")]

        XCTAssertEqual(engine.reclaimLastQuestion(), "zweite Frage")
        XCTAssertEqual(engine.messages.count, 2)
        XCTAssertEqual(engine.messages.first?.text, "erste Frage")
    }

    func testReclaimIsNilWithNoQuestion() {
        let engine = makeEngine()
        engine.messages = [ChatMessage(role: .assistant, text: "Today's brief")]
        XCTAssertNil(engine.reclaimLastQuestion(), "a brief-only thread has no question of the user's")
    }

    // MARK: - Connection test

    func testConnectionTestStartsUntested() {
        XCTAssertEqual(makeEngine().connectionTest, .untested)
    }

    func testConnectionTestReportsAMissingKey() async {
        let engine = makeEngine()
        engine.provider = .openAI      // a provider that genuinely requires a key
        engine.model = "gpt-4o"

        await engine.testConnection()

        guard case .failed(let message) = engine.connectionTest else {
            return XCTFail("expected a failure, got \(engine.connectionTest)")
        }
        XCTAssertEqual(message, AICoachError.noKey.errorDescription,
                       "the same wording the chat uses — not a second vocabulary for one problem")
    }

    func testChangingTheModelInvalidatesAnEarlierVerdict() async {
        let engine = makeEngine()
        engine.provider = .openAI
        engine.model = "gpt-4o"
        await engine.testConnection()          // no key ⇒ a real .failed verdict, no test-only hook
        XCTAssertNotEqual(engine.connectionTest, .untested, "premise: a verdict exists")

        engine.model = "gpt-4.1"

        XCTAssertEqual(engine.connectionTest, .untested,
                       "a tick earned by another model says nothing about this one — the endpoint can "
                       + "accept the key and still refuse the model")
    }
}
