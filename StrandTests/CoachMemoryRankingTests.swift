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
}
