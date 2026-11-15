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

    /// The cumulative totals used to append one element per REQUEST for the whole app run, so every
    /// `inputTokens` read reduced over an ever-growing array. They fold into one element now — the same
    /// four integers the persisted form always stored — while the sums stay exact.
    @MainActor
    func testCumulativeTotalsFoldIntoASingleRoundWithoutLosingTokens() {
        let log = CoachUsageLog.shared
        let before = log.sessionTotal.inputTokens

        log.beginTurn()
        for _ in 0..<50 { log.record(.init(inputTokens: 2, cacheReadTokens: 3, outputTokens: 1)) }

        XCTAssertEqual(log.sessionTotal.rounds.count, 1,
                       "the session total must accumulate, not collect one element per request")
        XCTAssertEqual(log.sessionTotal.inputTokens, before + 100)
        XCTAssertEqual(log.dayTotal.rounds.count, 1)
        XCTAssertEqual(log.lastTurn?.rounds.count, 50,
                       "the CURRENT question still needs its real round list — summaryLine counts it")
    }

    // MARK: - Cumulative summary line

    func testCumulativeSummaryLineUsesQuestionsNotRequests() {
        let turn = CoachUsageLog.Turn(rounds: [
            .init(inputTokens: 10, cacheReadTokens: 100, outputTokens: 5),
            .init(inputTokens: 20, cacheReadTokens: 100, outputTokens: 7)
        ])
        // Two rounds, but ONE question spread across a tool loop — the cumulative line must report the
        // question count it's given, not `turn.rounds.count` (that's what distinguishes it from
        // `summaryLine`, which is a single-question diagnostic).
        let line = CoachUsageLog.cumulativeSummaryLine(for: turn, questionCount: 1)
        XCTAssertTrue(line.contains("1 question ·"))
        XCTAssertFalse(line.contains("2 questions"))
        XCTAssertTrue(line.contains("30 in"))
        XCTAssertTrue(line.contains("200 cached"))
        XCTAssertTrue(line.contains("12 out"))
    }

    func testCumulativeSummaryLinePluralizesQuestions() {
        let line = CoachUsageLog.cumulativeSummaryLine(for: CoachUsageLog.Turn(), questionCount: 3)
        XCTAssertTrue(line.contains("3 questions ·"))
    }

    // MARK: - Session accumulation

    /// The session total must accumulate ACROSS questions rather than reset like `lastTurn` does. Asserts
    /// on the DELTA between two snapshots rather than an absolute value, since `CoachUsageLog.shared` is a
    /// real singleton other tests in this process also record into.
    @MainActor
    func testSessionTotalAccumulatesAcrossQuestions() {
        let log = CoachUsageLog.shared
        let before = (log.sessionTotal.inputTokens, log.sessionQuestionCount)

        log.beginTurn()
        log.record(.init(inputTokens: 111, outputTokens: 22))
        log.beginTurn()
        log.record(.init(inputTokens: 333, outputTokens: 44))

        XCTAssertEqual(log.sessionTotal.inputTokens, before.0 + 444,
                       "unlike lastTurn, the session total must not be reset by beginTurn")
        XCTAssertEqual(log.sessionQuestionCount, before.1 + 2,
                       "beginTurn is once per QUESTION, so two questions must add exactly two, " +
                       "regardless of how many rounds record() was called with")
    }

    // MARK: - Which reply shape carried the counts

    /// Dispatched on the shape of the usage object, because the gateways front several vendors behind one
    /// endpoint and a guess by provider would count nothing or count twice.
    func testTheAnthropicShapeIsRecognisedByItsOwnFieldNames() throws {
        let round = try XCTUnwrap(coachUsageRound(from: ["usage": [
            "input_tokens": 120, "cache_read_input_tokens": 3_800, "output_tokens": 240
        ]]))
        XCTAssertEqual(round.inputTokens, 120)
        XCTAssertEqual(round.cacheReadTokens, 3_800)
        XCTAssertEqual(round.outputTokens, 240)
    }

    func testTheOpenAIShapeSubtractsItsCachedTokens() throws {
        let round = try XCTUnwrap(coachUsageRound(from: ["usage": [
            "prompt_tokens": 1_000,
            "prompt_tokens_details": ["cached_tokens": 400],
            "completion_tokens": 50
        ]]))
        XCTAssertEqual(round.inputTokens, 600, "prompt_tokens includes the cached part")
        XCTAssertEqual(round.cacheReadTokens, 400)
        XCTAssertEqual(round.outputTokens, 50)
    }

    /// Gemini was counted as free before this: its usage lives under `usageMetadata`, which neither of
    /// the two shapes above matches.
    func testGeminiMetadataIsCountedAtAll() throws {
        let round = try XCTUnwrap(coachUsageRound(from: ["usageMetadata": [
            "promptTokenCount": 900, "cachedContentTokenCount": 300,
            "candidatesTokenCount": 120, "totalTokenCount": 1_020
        ]]))
        XCTAssertEqual(round.inputTokens, 600)
        XCTAssertEqual(round.cacheReadTokens, 300)
        XCTAssertEqual(round.cacheWriteTokens, 0, "Gemini reports no cache-write count, so none is made up")
        XCTAssertEqual(round.outputTokens, 120)
    }

    /// The model catalogues and the key-info endpoint pass through the same function. "Nothing was
    /// reported" is not "this cost nothing", so they must produce no round rather than a zero one.
    func testAReplyWithoutUsageProducesNoRound() {
        XCTAssertNil(coachUsageRound(from: ["data": [["id": "anthropic/claude-sonnet-4.6"]]]))
        XCTAssertNil(coachUsageRound(from: [:]))
    }

    // MARK: - Whose tokens these are

    /// Background work is about money, so it belongs in the session and day totals. It is not a question,
    /// so it must leave `lastTurn` alone: that line answers what the question just asked cost, and the
    /// brief landing on top of it was how a turn's cost got overwritten by work nobody asked for.
    @MainActor
    func testBackgroundWorkCountsTowardTheTotalsButNotTowardTheLastQuestion() {
        let log = CoachUsageLog.shared
        log.beginTurn()
        log.record(.init(inputTokens: 500, outputTokens: 60))
        let question = log.lastTurn
        let sessionBefore = log.sessionTotal.inputTokens
        let questionsBefore = log.sessionQuestionCount

        log.recordBackground(.init(inputTokens: 7_000, outputTokens: 900))

        XCTAssertEqual(log.lastTurn, question, "the last question's cost must still read as its own")
        XCTAssertEqual(log.sessionTotal.inputTokens, sessionBefore + 7_000)
        XCTAssertEqual(log.sessionQuestionCount, questionsBefore,
                       "background work is not a question and must not be counted as one")
    }

    /// The default is `background`, so a path nobody marked cannot claim to be the wearer's question.
    func testAnUnmarkedPathCountsAsBackground() {
        XCTAssertEqual(CoachUsageAttribution.current, .background)
    }
}
