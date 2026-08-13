import XCTest
@testable import Strand

/// Which questions the routing LEXICON is allowed to answer for, and what the cheap-model classifier's
/// reply is allowed to turn into.
///
/// The gap this closes: `CoachLocalQueryRouter`'s word lists are English/German, and they gate the tool
/// list for every provider — so an Italian question could never open history, catalog or log tools, and
/// nothing said why. English and German must keep going through the lexicon unchanged (its own tests
/// stay the specification); everything else goes to the cheap model.
final class CoachQuestionRoutingTests: XCTestCase {

    // MARK: - Language coverage

    func testEnglishAndGermanAreCoveredByTheLexicon() {
        XCTAssertTrue(CoachQuestionLanguage.lexiconCovers(
            "how did my weight develop over the last twelve months?"))
        XCTAssertTrue(CoachQuestionLanguage.lexiconCovers(
            "wie hat sich mein Gewicht in den letzten zwölf Monaten entwickelt?"))
    }

    func testItalianIsNotCoveredAndThereforeGoesToTheModel() {
        XCTAssertFalse(CoachQuestionLanguage.lexiconCovers(
            "quanti allenamenti ho fatto negli ultimi novanta giorni?"))
    }

    /// A two-word question is genuinely ambiguous to any detector. Treating it as covered keeps an
    /// English user off the network for "ok?" — the lexicon missing it is no worse than a coin flip.
    func testTooShortToJudgeCountsAsCovered() {
        XCTAssertTrue(CoachQuestionLanguage.lexiconCovers("ok?"))
        XCTAssertTrue(CoachQuestionLanguage.lexiconCovers("5k?"))
    }

    // MARK: - The lexicon's verdict as a value

    func testLexiconRoutingMatchesTheRouterItWraps() {
        let question = "show me my weight history over the last 365 days"
        let routing = CoachQuestionRouting.lexicon(for: question, knownJournalQuestions: [])
        XCTAssertEqual(routing.historyDays, CoachLocalQueryRouter.explicitHistoryDays(for: question))
        XCTAssertEqual(routing.wantsDataCatalog,
                       CoachLocalQueryRouter.requestsDataCatalog(for: question))
        XCTAssertEqual(routing.wantsWorkoutHistory,
                       CoachLocalQueryRouter.requestsWorkoutHistory(for: question))
    }

    func testOrdinaryCoachingQuestionOpensNothingExtra() {
        let routing = CoachQuestionRouting.lexicon(for: "how should I train today?",
                                                    knownJournalQuestions: [])
        XCTAssertNil(routing.historyDays)
        XCTAssertFalse(routing.wantsDataCatalog)
        XCTAssertFalse(routing.wantsPersonalLogs)
    }

    // MARK: - Parsing the classifier's reply

    func testParsesAPlainJSONVerdict() {
        let routing = AICoachEngine.parseRouting(
            #"{"history_days": 90, "workout_history": true, "data_catalog": false, "personal_logs": false}"#)
        XCTAssertEqual(routing?.historyDays, 90)
        XCTAssertEqual(routing?.wantsWorkoutHistory, true)
        XCTAssertEqual(routing?.wantsDataCatalog, false)
    }

    func testParsesJSONWrappedInProseOrAFence() {
        let routing = AICoachEngine.parseRouting("""
        Sure! ```json
        {"history_days": null, "workout_history": false, "data_catalog": true, "personal_logs": false}
        ``` Hope that helps.
        """)
        XCTAssertNil(routing?.historyDays)
        XCTAssertEqual(routing?.wantsDataCatalog, true)
    }

    /// A window the model invented must not widen the read beyond what the tool itself allows.
    func testAnAbsurdWindowIsClamped() {
        let routing = AICoachEngine.parseRouting(#"{"history_days": 999999}"#)
        XCTAssertEqual(routing?.historyDays, 3_650)
    }

    /// Anything unparsable must fall back to the lexicon rather than opening a tool on a guess — the
    /// caller does that when this returns nil, so nil is the contract.
    func testUnparsableRepliesYieldNoRouting() {
        XCTAssertNil(AICoachEngine.parseRouting("I think you want your workout history."))
        XCTAssertNil(AICoachEngine.parseRouting(""))
    }

    func testMissingFlagsDefaultToFalse() {
        let routing = AICoachEngine.parseRouting(#"{"history_days": 7}"#)
        XCTAssertEqual(routing?.historyDays, 7)
        XCTAssertEqual(routing?.wantsWorkoutHistory, false)
        XCTAssertEqual(routing?.wantsDataCatalog, false)
        XCTAssertEqual(routing?.wantsPersonalLogs, false)
    }
}
