import XCTest
@testable import Strand

/// The counters exist to make one specific silent failure visible: Anthropic's prompt cache only engages
/// once the cached prefix clears a model-dependent minimum, and below it the API caches nothing without
/// saying so. These tests pin the parsing and, above all, that a zero-cache turn is *reported* as such
/// rather than passed off as a hit.
final class CoachUsageLogTests: XCTestCase {

    // MARK: - Parsing a usage object

    func testParsesAllFourCounters() {
        let round = AnthropicClient.parseUsage([
            "input_tokens": 120,
            "cache_read_input_tokens": 3800,
            "cache_creation_input_tokens": 0,
            "output_tokens": 240
        ])
        XCTAssertEqual(round.inputTokens, 120)
        XCTAssertEqual(round.cacheReadTokens, 3800)
        XCTAssertEqual(round.cacheWriteTokens, 0)
        XCTAssertEqual(round.outputTokens, 240)
    }

    /// A reply with no cache fields at all must read as "no caching" — zeros, not a crash and not a guess.
    func testMissingCacheFieldsReadAsZeroRatherThanFailing() {
        let round = AnthropicClient.parseUsage(["input_tokens": 900, "output_tokens": 100])
        XCTAssertEqual(round.inputTokens, 900)
        XCTAssertEqual(round.cacheReadTokens, 0)
        XCTAssertEqual(round.cacheWriteTokens, 0)
    }

    func testEmptyUsageObjectIsAllZeros() {
        XCTAssertEqual(AnthropicClient.parseUsage([:]), CoachUsageLog.Round())
    }

    // MARK: - The cache breakpoint

    /// The breakpoint must sit on the system block: Anthropic renders tools → system → messages, so this
    /// is what caches the tool definitions and the prompt together.
    func testSystemCarriesAnEphemeralCacheBreakpoint() {
        let blocks = AnthropicClient.cacheableSystem("You are a coach.")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, "You are a coach.")
        XCTAssertEqual((blocks[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
    }

    /// Caching is a prefix match — the prompt must go out byte-for-byte or every request misses.
    func testSystemTextIsPassedThroughUnaltered() {
        let prompt = "Line one.\n\n  Indented — with an em dash, ümlauts and a trailing space. "
        let blocks = AnthropicClient.cacheableSystem(prompt)
        XCTAssertEqual(blocks[0]["text"] as? String, prompt)
    }

    // MARK: - Totals across a multi-round turn

    /// One question can span several tool rounds; the diagnostic must report the whole turn, not the
    /// last round — otherwise a 5-round answer looks as cheap as a 1-round one.
    func testTurnSumsEveryRound() {
        let turn = CoachUsageLog.Turn(rounds: [
            .init(inputTokens: 4000, cacheReadTokens: 0, cacheWriteTokens: 4000, outputTokens: 50),
            .init(inputTokens: 120, cacheReadTokens: 4000, cacheWriteTokens: 0, outputTokens: 80),
            .init(inputTokens: 200, cacheReadTokens: 4000, cacheWriteTokens: 0, outputTokens: 300)
        ])
        XCTAssertEqual(turn.inputTokens, 4320)
        XCTAssertEqual(turn.cacheReadTokens, 8000)
        XCTAssertEqual(turn.cacheWriteTokens, 4000)
        XCTAssertEqual(turn.outputTokens, 430)
    }

    // MARK: - The verdict — the whole point of the feature

    /// The failure this feature exists to expose: the prefix never cleared the model's minimum, so the
    /// cache silently did nothing. The line must SAY so, not stay quiet.
    func testAllZeroCacheIsReportedAsNoCachingNotAsSuccess() {
        let turn = CoachUsageLog.Turn(rounds: [.init(inputTokens: 900, outputTokens: 100)])
        let verdict = CoachUsageLog.cacheVerdict(for: turn).lowercased()
        XCTAssertTrue(verdict.contains("no caching"))
        XCTAssertFalse(verdict.contains("cache hit"))
        // It must also reassure: nothing broke and nothing extra was paid.
        XCTAssertTrue(verdict.contains("nothing is broken"))
    }

    func testCacheReadIsReportedAsAHit() {
        let turn = CoachUsageLog.Turn(rounds: [.init(inputTokens: 100, cacheReadTokens: 3800)])
        XCTAssertTrue(CoachUsageLog.cacheVerdict(for: turn).lowercased().contains("cache hit"))
    }

    /// The seeding round writes but cannot read — that is normal, not a failure, and must not be
    /// reported as "no caching".
    func testFirstRoundWriteIsDistinguishedFromNoCaching() {
        let turn = CoachUsageLog.Turn(rounds: [.init(inputTokens: 100, cacheWriteTokens: 4000)])
        let verdict = CoachUsageLog.cacheVerdict(for: turn).lowercased()
        XCTAssertTrue(verdict.contains("written"))
        XCTAssertFalse(verdict.contains("no caching"))
    }

    // MARK: - Summary line

    func testSummaryLineUsesSingularForOneRequest() {
        let turn = CoachUsageLog.Turn(rounds: [.init(inputTokens: 10, outputTokens: 5)])
        XCTAssertTrue(CoachUsageLog.summaryLine(for: turn).contains("1 request ·"))
    }

    func testSummaryLineCountsEveryRoundAndReportsCachedTokens() {
        let turn = CoachUsageLog.Turn(rounds: [
            .init(inputTokens: 10, cacheReadTokens: 4000, outputTokens: 5),
            .init(inputTokens: 20, cacheReadTokens: 4000, outputTokens: 7)
        ])
        let line = CoachUsageLog.summaryLine(for: turn)
        XCTAssertTrue(line.contains("2 requests"))
        XCTAssertTrue(line.contains("8000 cached"))
        XCTAssertTrue(line.contains("30 in"))
        XCTAssertTrue(line.contains("12 out"))
    }

    // MARK: - Turn boundaries

    @MainActor
    func testBeginTurnDropsThePreviousQuestionsRounds() {
        let log = CoachUsageLog.shared
        log.beginTurn()
        log.record(.init(inputTokens: 999))
        XCTAssertEqual(log.lastTurn?.rounds.count, 1)

        log.beginTurn()
        log.record(.init(inputTokens: 5))
        XCTAssertEqual(log.lastTurn?.rounds.count, 1, "a new question must not inherit the last one's rounds")
        XCTAssertEqual(log.lastTurn?.inputTokens, 5)
    }
}
