import XCTest
@testable import Strand

/// Pins `CoachMemory.relevanceScore`'s recency-decay: keyword overlap decayed by age
/// (`overlap * exp(-ageDays / halfLife)`), so an old fact's relevance actually fades instead of only
/// ever breaking an exact-overlap tie. Pure model tests — no engine, no provider, no disk.
@MainActor
final class CoachMemoryRankingTests: XCTestCase {

    private func fact(_ text: String, daysAgo: Double, now: Date) -> CoachMemory.MemoryFact {
        CoachMemory.MemoryFact(text: text, createdAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    // MARK: - The formula itself

    func testZeroOverlapScoresZeroRegardlessOfAge() {
        let now = Date()
        let f = fact("running three times a week", daysAgo: 0, now: now)
        XCTAssertEqual(CoachMemory.relevanceScore(f, ["knee"], now: now), 0)
    }

    func testNormalFactsWithNoTopicOverlapStayOutOfThePrompt() {
        let now = Date()
        let sleep = fact("prefers a consistent bedtime", daysAgo: 0, now: now)
        let memory = seededMemory([sleep])

        XCTAssertTrue(memory.relevantFacts(for: "How should I train my legs today?", limit: 8, now: now).isEmpty,
                      "ranking zero-score ties must not disclose unrelated normal memories")
    }

    func testFreshFactScoresTheRawOverlap() {
        let now = Date()
        let f = fact("left knee pain when running", daysAgo: 0, now: now)
        let qTokens = CoachMemory.tokens("how does my knee feel")
        let score = CoachMemory.relevanceScore(f, qTokens, now: now)
        // At age 0, exp(0) == 1, so the score is exactly the raw overlap count.
        let rawOverlap = CoachMemory.tokens(f.text).intersection(qTokens).count
        XCTAssertEqual(score, Double(rawOverlap))
    }

    func testScoreHalvesAtOneHalfLife() {
        let now = Date()
        let fresh = fact("left knee pain when running", daysAgo: 0, now: now)
        let halfLifeOld = fact("left knee pain when running", daysAgo: CoachMemory.recencyHalfLifeDays, now: now)
        let q = CoachMemory.tokens("knee pain")
        let freshScore = CoachMemory.relevanceScore(fresh, q, now: now)
        let oldScore = CoachMemory.relevanceScore(halfLifeOld, q, now: now)
        XCTAssertEqual(oldScore, freshScore / 2, accuracy: 0.0001)
    }

    /// The exact scenario the fix targets: an old fact with MORE overlap no longer automatically beats a
    /// recent fact with LESS overlap once it's decayed past a point — recency is a real factor now, not
    /// only a tiebreak between equal overlap counts.
    func testAnOldHighOverlapFactCanBeOutrankedByARecentLowerOverlapOne() {
        let now = Date()
        let q = CoachMemory.tokens("sore knee after runs")   // {"sore", "knee", "after", "runs"}
        // 4-token overlap with q, but 90 days old (3 half-lives): score = 4 * (1/2)^3 = 0.5.
        let old = fact("sore left knee after long runs", daysAgo: 90, now: now)
        // 1-token overlap ("knee"), fresh today: score = 1 * 1 = 1.
        let recent = fact("knee feels fine today", daysAgo: 0, now: now)
        XCTAssertGreaterThan(CoachMemory.relevanceScore(recent, q, now: now),
                             CoachMemory.relevanceScore(old, q, now: now),
                             "a fresh, weaker match should now outrank a 90-day-old stronger one")
    }

    // MARK: - End to end through relevantFacts (seeded via UserDefaults, mirrors persistence)

    /// Seeds `CoachMemory`'s persisted facts directly (JSON under its storage key), the only way to give
    /// a fact a specific `createdAt` in the past — `add(_:)` always stamps `Date()`. Mirrors
    /// `CoachMemory`'s own private `factsKey` value; if that key ever changes this seed silently stops
    /// working, which the `XCTAssertEqual(memory.facts.count, ...)` sanity check below would catch.
    private func seededMemory(_ facts: [CoachMemory.MemoryFact]) -> CoachMemory {
        let suite = "CoachMemoryRankingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let data = try! JSONEncoder().encode(facts)
        defaults.set(data, forKey: "ai.memory.facts")
        return CoachMemory(defaults: defaults)
    }

    func testRelevantFactsOrdersByDecayedScoreNotRawOverlap() {
        let now = Date()
        let old = fact("sore left knee after long runs", daysAgo: 90, now: now)
        let recent = fact("knee feels fine today", daysAgo: 0, now: now)
        let memory = seededMemory([old, recent])
        XCTAssertEqual(memory.facts.count, 2, "seed must have landed — factsKey drifted otherwise")

        let ranked = memory.relevantFacts(for: "sore knee after runs", limit: 5, now: now)
        XCTAssertEqual(ranked.first?.text, recent.text,
                       "the fresh, weaker-overlap fact should rank first now")
    }

    // MARK: - Not saying the same thing twice

    /// Two independent retrievers hold the same facts — this keyword ranking, and the on-device
    /// semantic index, which stores each fact as a `[Memory]` document. Both run every turn, so without
    /// this filter the same sentence goes on the wire twice, once bare and once behind a
    /// "Confirmed memory:" prefix.
    func testAFactAlreadyInTheContextIsNotRestated() {
        let f = fact("left knee pain when running", daysAgo: 0, now: Date())
        let context = """
        RELEVANT LOCAL TEXT MEMORY (retrieved on device; treat as user-provided context):
        • [Memory] Confirmed memory: left knee pain when running
        """
        XCTAssertTrue(CoachMemory.factsNotAlreadyInContext([f], context: context).isEmpty)
    }

    /// Matching is on the normalised form, so punctuation and casing differences between the two
    /// renderings don't defeat it.
    func testTheMatchIgnoresPunctuationAndCasing() {
        let f = fact("Left knee pain, when running.", daysAgo: 0, now: Date())
        let context = "• [Memory] Confirmed memory: left knee pain when running"
        XCTAssertTrue(CoachMemory.factsNotAlreadyInContext([f], context: context).isEmpty)
    }

    func testAnUnrelatedFactSurvivesTheFilter() {
        let f = fact("prefers a consistent bedtime", daysAgo: 0, now: Date())
        let context = "• [Memory] Confirmed memory: left knee pain when running"
        XCTAssertEqual(CoachMemory.factsNotAlreadyInContext([f], context: context).map(\.text), [f.text])
    }

    func testAnEmptyContextFiltersNothing() {
        let f = fact("prefers a consistent bedtime", daysAgo: 0, now: Date())
        XCTAssertEqual(CoachMemory.factsNotAlreadyInContext([f], context: "").count, 1)
    }

    // MARK: - Pinned facts must not spend the relevance budget

    private func pinned(_ text: String, now: Date) -> CoachMemory.MemoryFact {
        CoachMemory.MemoryFact(text: text, category: .injury, importance: .pinned,
                               createdAt: now, verification: .confirmed)
    }

    /// Pinned facts already ride every prompt via `pinnedBlock`, and `relevantBlock` discards them —
    /// but they used to be counted against the same `limit` first. At `limit: 8` (what all three
    /// callers pass) eight pinned facts left a budget of zero, so the block came back empty however
    /// well a stored fact matched the question.
    func testPinnedFactsDoNotCrowdOutTheRelevanceBlock() {
        let now = Date()
        let pins = (0..<8).map { pinned("pinned constraint number \($0)", now: now) }
        let relevant = fact("left knee pain when running downhill", daysAgo: 0, now: now)
        let memory = seededMemory(pins + [relevant])

        let block = memory.relevantBlock(for: "my knee hurts when running", limit: 8)
        XCTAssertTrue(block.contains("left knee pain when running downhill"),
                      "eight pinned facts must not consume the whole retrieval budget")
    }

    /// A pinned fact that is not yet confirmed is filtered out by the block too, so it must not spend
    /// a slot either — the same waste one rung down.
    func testUnconfirmedPinnedFactsAlsoSpendNoBudget() {
        let now = Date()
        let unconfirmed = CoachMemory.MemoryFact(text: "possible hip issue", category: .injury,
                                                 importance: .pinned, createdAt: now,
                                                 verification: .pendingConfirmation)
        let relevant = fact("hip mobility work every morning", daysAgo: 0, now: now)
        let memory = seededMemory([unconfirmed, relevant])

        let block = memory.relevantBlock(for: "what should I do about my hip", limit: 1)
        XCTAssertTrue(block.contains("hip mobility work every morning"))
        XCTAssertFalse(block.contains("possible hip issue"),
                       "a pinned fact never belongs in this block, confirmed or not")
    }

    // MARK: - Stopwords in the languages the app ships

    /// The disclosure guard (`filter { score > 0 }`) only holds if function words are filtered. With an
    /// English-only stopword list a German question and an unrelated German fact shared `ich`, which
    /// scored above zero and put the fact in the prompt.
    func testGermanFunctionWordsDoNotMakeAFactRelevant() {
        let now = Date()
        let unrelated = fact("Ich schlafe meistens sieben Stunden", daysAgo: 0, now: now)
        let memory = seededMemory([unrelated])

        XCTAssertTrue(memory.relevantBlock(for: "Wie soll ich heute trainieren?", limit: 8).isEmpty,
                      "sharing only 'ich' is not a reason to disclose a stored fact")
    }

    /// …and the list must not overshoot: a real German content word still retrieves.
    func testGermanContentWordsStillRetrieve() {
        let now = Date()
        let knee = fact("Linkes Knie schmerzt beim Bergablaufen", daysAgo: 0, now: now)
        let memory = seededMemory([knee])

        XCTAssertTrue(memory.relevantBlock(for: "Mein Knie tut weh", limit: 8)
            .contains("Linkes Knie schmerzt"),
                      "filtering function words must not also filter the topic")
    }

    /// One unmistakable function word per shipped locale, each 3+ chars so `tokens` can reach it.
    ///
    /// This used to probe seven of the ten and still be called "the shipped languages", which is how `pl`
    /// went out with no stopwords at all: every Polish function word counted as topic overlap, in the keyword
    /// ranker, in the rescue arm and in the near-duplicate check. The two Chinese locales are covered by the
    /// separate ideographic case below — a word-level list has nothing to match there, by design — so the
    /// count here is eight, and the name now means what it says.
    func testStopwordsCoverTheShippedLanguages() {
        let probes = ["en": "the", "de": "und", "es": "que", "fr": "les",
                      "it": "che", "pt-PT": "com", "ru": "как", "pl": "jest"]
        for (locale, word) in probes {
            XCTAssertTrue(CoachMemory.tokens(word).isEmpty,
                          "'\(word)' (\(locale)) is a function word and must not survive tokenisation")
        }
    }

    /// Polish content words must still retrieve — a stopword list that swallows the topic is worse than none.
    func testPolishContentWordsStillRetrieve() {
        let tokens = CoachMemory.tokens("Czy magnez pomaga mi zasnąć?")
        XCTAssertTrue(tokens.contains("magnez"))
        XCTAssertTrue(tokens.contains("pomaga"))
        XCTAssertFalse(tokens.contains("czy"))
    }

    /// End to end through the block the send path actually appends.
    func testRelevantBlockSkipsWhatTheSemanticIndexAlreadySupplied() {
        let now = Date()
        let knee = fact("left knee pain when running", daysAgo: 0, now: now)
        let sleep = fact("sleeps badly when running late", daysAgo: 0, now: now)
        let memory = seededMemory([knee, sleep])

        let context = "• [Memory] Confirmed memory: left knee pain when running"
        let block = memory.relevantBlock(for: "running and my knee", limit: 8, alreadyInContext: context)
        XCTAssertFalse(block.contains("left knee pain when running"),
                       "the semantic index already supplied this one")
        XCTAssertTrue(block.contains("sleeps badly when running late"))
    }
}
