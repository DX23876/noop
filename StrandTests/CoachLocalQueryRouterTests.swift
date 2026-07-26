import XCTest
@testable import Strand

@MainActor
final class CoachLocalQueryRouterTests: XCTestCase {
    func testRecognisesExplicitMultiYearWeightQuestion() {
        XCTAssertEqual(CoachLocalQueryRouter.metricHistoryRequest(for: "How has my weight changed over 3 years?"),
                       .init(metric: "weight", days: 1_095))
    }

    func testRecognisesGermanLongTermFerritinQuestion() {
        XCTAssertEqual(CoachLocalQueryRouter.metricHistoryRequest(for: "Wie war mein Ferritin Verlauf über die letzten 2 Jahre?"),
                       .init(metric: "ferritin", days: 730))
    }

    func testDoesNotFetchDeepHistoryForAnOrdinaryTrainingQuestion() {
        XCTAssertNil(CoachLocalQueryRouter.metricHistoryRequest(for: "Should I run today?"))
    }

    func testBoundsRequestedHistoryToTenYears() {
        XCTAssertEqual(CoachLocalQueryRouter.metricHistoryRequest(for: "Show my HRV trend over 99 years"),
                       .init(metric: "hrv", days: 3_650))
    }

    func testRecognisesLongHistoryEvenWhenTheMetricNeedsLocalCatalogMatching() {
        XCTAssertEqual(CoachLocalQueryRouter.explicitHistoryDays(for: "How has my vitamin D changed over 2 years?"), 730)
        XCTAssertNil(CoachLocalQueryRouter.metricHistoryRequest(for: "How has my vitamin D changed over 2 years?"))
    }

    func testCatalogAndPersonalLogsRequireExplicitQuestionWording() {
        XCTAssertFalse(CoachLocalQueryRouter.requestsDataCatalog(for: "Should I run today?"))
        XCTAssertTrue(CoachLocalQueryRouter.requestsDataCatalog(for: "Welche Daten habe ich lokal?"))
        XCTAssertTrue(CoachLocalQueryRouter.requestsDataCatalog(for: "How has my vitamin D changed over 2 years?"))

        XCTAssertFalse(CoachLocalQueryRouter.requestsPersonalLogs(for: "Should I run today?"))
        XCTAssertTrue(CoachLocalQueryRouter.requestsPersonalLogs(for: "Was habe ich in meinem Tagebuch notiert?"))
    }

    func testAUserDefinedJournalFieldIsRecognisedOnlyForAnExplicitRecallQuestion() {
        let fields = ["Did you take fish oil?", "CBD oil (mg)"]
        XCTAssertTrue(CoachLocalQueryRouter.requestsPersonalLogs(for: "Did I take fish oil last week?",
                                                                   knownQuestions: fields))
        XCTAssertFalse(CoachLocalQueryRouter.requestsPersonalLogs(for: "Is fish oil useful for recovery?",
                                                                    knownQuestions: fields))
        XCTAssertFalse(CoachLocalQueryRouter.requestsPersonalLogs(for: "Did I run last week?",
                                                                    knownQuestions: fields),
                       "question grammar must never match the 'Did you …' prefix of a journal field")
    }

    func testSensitiveJournalPolicyRecognisesOnlyTheNarrowLocalTerms() {
        XCTAssertTrue(CoachSensitiveJournalPolicy.isSensitive(label: "CBD oil (mg)"))
        XCTAssertTrue(CoachSensitiveJournalPolicy.isSensitive(label: "Did you feel sick or ill?"))
        XCTAssertTrue(CoachSensitiveJournalPolicy.isSensitive(label: "Masturbation"))
        XCTAssertTrue(CoachSensitiveJournalPolicy.isSensitive(label: "Hast du dich in deiner Beziehung belastet gefühlt?"))
        XCTAssertTrue(CoachSensitiveJournalPolicy.isSensitive(label: "Intime Gesundheit"))
        XCTAssertFalse(CoachSensitiveJournalPolicy.isSensitive(label: "Fish oil (mg)"))
        XCTAssertFalse(CoachSensitiveJournalPolicy.isSensitive(label: "Did you take magnesium?"))
    }

    func testLocalPolicyDoesNotOfferDeepHistoryOrLogsForAnOrdinaryQuestion() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-local-policy-\(UUID().uuidString)"))
        engine.toolConsent = ToolConsent(enabled: Set(CoachPurpose.allCases))

        let ordinary = engine.coachTools(for: "Should I run today?")
        XCTAssertFalse(ordinary.contains(.dataCatalog))
        XCTAssertFalse(ordinary.contains(.metricHistory))
        XCTAssertFalse(ordinary.contains(.myLogs))

        let trend = engine.coachTools(for: "How has my weight changed over 3 years?")
        XCTAssertTrue(trend.contains(.dataCatalog))
        XCTAssertTrue(trend.contains(.metricHistory))
        XCTAssertFalse(trend.contains(.myLogs))

        let journal = engine.coachTools(for: "Was habe ich in meinem Tagebuch notiert?")
        XCTAssertTrue(journal.contains(.myLogs))
        XCTAssertFalse(journal.contains(.dataCatalog))
        XCTAssertFalse(journal.contains(.metricHistory))
    }

    func testSensitiveJournalQuestionGetsOnlyTheDedicatedReader() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-sensitive-journal-policy-\(UUID().uuidString)"))
        engine.toolConsent = ToolConsent(enabled: Set(CoachPurpose.allCases))

        let sensitive = engine.coachTools(
            for: "Habe ich diese Woche CBD verwendet?",
            journalQuestions: ["CBD oil (mg)", "Did you take fish oil?"]
        )
        XCTAssertTrue(sensitive.contains(.sensitiveLogs))
        XCTAssertFalse(sensitive.contains(.myLogs))

        let ordinary = engine.coachTools(
            for: "Did I take fish oil this week?",
            journalQuestions: ["CBD oil (mg)", "Did you take fish oil?"]
        )
        XCTAssertTrue(ordinary.contains(.myLogs))
        XCTAssertFalse(ordinary.contains(.sensitiveLogs))
    }
}
