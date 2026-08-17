import XCTest
@testable import Strand

/// Pins `CoachMemory.tokens` across scripts. Latin text keeps the word rule it always had; ideographic
/// text is reached through character bigrams instead of coming back as one clause-sized token that only
/// ever matched an identical clause. Every keyword-overlap caller in the coach depends on this —
/// semantic retrieval's keyword arm, `relevanceScore`, conversation recall, the near-duplicate check.
@MainActor
final class CoachMemoryTokenizerTests: XCTestCase {

    // MARK: - The word path must not move

    func testLatinTokenisationIsUnchanged() {
        XCTAssertEqual(CoachMemory.tokens("Mein linkes Knie schmerzt nach dem Lauf!"),
                       ["linkes", "knie", "schmerzt", "lauf"],
                       "function words and sub-3-character words still drop out, nothing else changes")
        XCTAssertEqual(CoachMemory.tokens("I go to the gym"), ["gym"])
        XCTAssertEqual(CoachMemory.tokens("HRV 42"), ["hrv"])
    }

    // MARK: - Ideographic text

    func testAChineseClauseIsCutIntoBigramsInsteadOfOneToken() {
        let tokens = CoachMemory.tokens("我的睡眠质量很差")
        XCTAssertEqual(tokens.count, 7, "eight characters yield seven adjacent pairs")
        XCTAssertTrue(tokens.allSatisfy { $0.count == 2 })
        XCTAssertTrue(tokens.contains("睡眠"))
        XCTAssertFalse(tokens.contains("我的睡眠质量很差"),
                       "the whole clause as a token is exactly what matched nothing before")
    }

    func testRelatedChineseTextsShareTokensAndUnrelatedOnesDoNot() {
        let question = CoachMemory.tokens("睡眠质量怎么样")
        let related = CoachMemory.tokens("最近睡眠质量变差")
        let unrelated = CoachMemory.tokens("膝盖在跑步后疼痛")

        XCTAssertEqual(question.intersection(related), ["睡眠", "眠质", "质量"])
        XCTAssertTrue(question.intersection(unrelated).isEmpty)
    }

    func testMixedScriptKeepsBothTheLatinWordAndTheBigrams() {
        let tokens = CoachMemory.tokens("HRV低于平均")
        XCTAssertTrue(tokens.contains("hrv"))
        XCTAssertTrue(tokens.isSuperset(of: ["低于", "于平", "平均"]))
    }

    func testASingleIdeographSurvivesOnItsOwn() {
        // A one-character run has no pair to form; dropping it would lose the shortest questions.
        XCTAssertEqual(CoachMemory.tokens("痛?"), ["痛"])
    }

    func testJapaneseKanaIsSegmentedTheSameWay() {
        // Not a shipped language, but the same script family: it must not regress to one token either.
        let tokens = CoachMemory.tokens("すいみん")
        XCTAssertEqual(tokens, ["すい", "いみ", "みん"])
    }

    // MARK: - What it actually buys, end to end

    /// The consequence that reaches the user: `relevantFacts` drops every fact scoring zero, so before
    /// this a Chinese question surfaced NO stored fact at all — the memory block was always empty.
    func testChineseQuestionRetrievesTheMatchingFactAndNotTheUnrelatedOne() {
        let now = Date()
        let sleep = CoachMemory.MemoryFact(text: "最近睡眠质量变差", createdAt: now)
        let knee = CoachMemory.MemoryFact(text: "膝盖在跑步后疼痛", createdAt: now)
        let memory = seededMemory([sleep, knee])
        XCTAssertEqual(memory.facts.count, 2, "seed must have landed — factsKey drifted otherwise")

        let ranked = memory.relevantFacts(for: "我的睡眠质量怎么样", limit: 5, now: now)
        XCTAssertEqual(ranked.map(\.text), [sleep.text])
    }

    /// Mirrors `CoachMemoryRankingTests.seededMemory`: facts are persisted JSON, and only seeding them
    /// directly gives a fact a chosen `createdAt`.
    private func seededMemory(_ facts: [CoachMemory.MemoryFact]) -> CoachMemory {
        let suite = "CoachMemoryTokenizerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let data = try! JSONEncoder().encode(facts)
        defaults.set(data, forKey: "ai.memory.facts")
        return CoachMemory(defaults: defaults)
    }
}
