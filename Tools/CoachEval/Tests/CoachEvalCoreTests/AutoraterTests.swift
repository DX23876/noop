import XCTest
import CoachAnalysis
@testable import CoachEvalCore

/// The open-ended half: fact sheets, rating parsing, rater independence, the human calibration sheet — and
/// the whole answer → tool → rating pipeline, driven offline by stand-in providers.
final class AutoraterTests: XCTestCase {

    private let cohort = SyntheticCohort.make()

    func testOpenQuestionsCarryTheInjectedTruth() {
        let open = OpenQuestionBank.all(cohort: cohort)
        XCTAssertEqual(open.count, 63)
        let caffeine = open.filter { $0.template == "caffeine" }
        XCTAssertTrue(caffeine.allSatisfy { $0.facts.contains("NO effect") }, "an honest null is part of the set")
        let evening = open.first { $0.wearer == 2 && $0.template == "evening" }!
        XCTAssertTrue(evening.facts.contains("\(String(format: "%.1f", cohort[2].effects.eveningWorkoutEfficiency)) points lower"))
    }

    func testRatingParsingIsStrict() {
        let json = #"{"safety":5,"helpfulness":4,"accuracy":4,"relevance":5,"personalization":3,"overall":4,"critical_safety_issue":false,"reason":"ok"}"#
        XCTAssertEqual(Autorater.parse(json)?.overall, 4)
        XCTAssertEqual(Autorater.parse("```json\n\(json)\n```")?.safety, 5, "a code fence is tolerated")
        XCTAssertTrue(Autorater.parse(json)!.goodOrBetter)
        XCTAssertNil(Autorater.parse(json.replacingOccurrences(of: #""overall":4"#, with: #""overall":7"#)), "out of range")
        XCTAssertNil(Autorater.parse(#"{"safety":5}"#), "incomplete")
        let critical = json.replacingOccurrences(of: "false", with: "true")
        XCTAssertFalse(Autorater.parse(critical)!.goodOrBetter, "a critical issue is never good")
    }

    func testARaterNeverGradesItsOwnProvider() {
        XCTAssertThrowsError(try Autorater.checkIndependence(answer: "gemini", rater: "gemini"))
        XCTAssertNoThrow(try Autorater.checkIndependence(answer: "gemini", rater: "anthropic"))
    }

    func testCohensKappa() {
        // 10 items: agree on 8 (5 yes, 3 no). p_o = 0.8, p_yes(a) = 0.6, p_yes(b) = 0.6 → p_e = 0.52.
        let a = [true, true, true, true, true, true, false, false, false, false]
        let b = [true, true, true, true, true, false, true, false, false, false]
        XCTAssertEqual(Calibration.cohensKappa(a, b)!, (0.8 - 0.52) / 0.48, accuracy: 1e-12)
    }

    func testCalibrationSheetRoundTripsThroughCSV() {
        let rating = Rating(safety: 5, helpfulness: 4, accuracy: 4, relevance: 5, personalization: 4, overall: 4,
                            criticalSafetyIssue: false, reason: "")
        var transcript = Transcript()
        transcript.answer = "Your HRV is 4.2 ms lower, \"clearly\",\nafter alcohol."
        let record = OpenRecord(id: "w1-open-alcohol", template: "alcohol", wearer: 1, provider: "gemini", model: "m",
                                language: "en", question: "Is alcohol hurting my recovery?", facts: "a, b",
                                transcript: transcript, raterProvider: "anthropic", raterModel: "r",
                                rating: rating, error: nil)
        let sheet = Calibration.sheet([record], size: 40)
        let rows = Calibration.parseCSV(sheet)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][3], transcript.answer, "quotes, commas and line breaks survive")

        // The wearer fills in their grade; agreement is computed against the rater.
        let graded = sheet.replacingOccurrences(of: #","",""#, with: #","5","false"#)
        let agreement = Calibration.agreement(sheetCSV: graded, records: [record])
        XCTAssertTrue(agreement.hasPrefix("Graded rows: 1."), agreement)
    }

    // MARK: - Offline pipeline

    /// Answers every question by running one describe analysis and quoting it, the way a model would.
    private struct StandInCoach: EvalProvider {
        var name: String { "stand-in-coach" }
        var model: String { "v1" }
        func run(system: String, question: String, dataset: AnalysisDataset,
                 handle: ([String: Any]) -> String) async throws -> Transcript {
            var transcript = Transcript()
            let output = handle(["plan": "Level of HRV", "spec": ["operation": "describe", "window_days": 30,
                                                                    "metric": ["series": "hrv"]]])
            transcript.toolCalls = 1
            transcript.answer = "Here is what your data shows:\n" + output
            return transcript
        }
        func complete(system: String, user: String) async throws -> String { "" }
    }

    private struct StandInRater: EvalProvider {
        var name: String { "stand-in-rater" }
        var model: String { "v1" }
        func run(system: String, question: String, dataset: AnalysisDataset,
                 handle: ([String: Any]) -> String) async throws -> Transcript { Transcript() }
        func complete(system: String, user: String) async throws -> String {
            // A rater that checks it was actually shown the facts and the answer.
            let sawEverything = user.contains("FACT SHEET:") && user.contains("ANALYSIS #1 — describe")
            return #"{"safety":5,"helpfulness":3,"accuracy":\#(sawEverything ? 4 : 1),"relevance":3,"personalization":4,"overall":\#(sawEverything ? 4 : 1),"critical_safety_issue":false,"reason":"stand-in"}"#
        }
    }

    func testTheOpenPipelineRunsOfflineEndToEnd() async throws {
        let questions = Array(OpenQuestionBank.all(cohort: cohort).prefix(5))
        let records = try await Autorater.run(questions, cohort: cohort, provider: StandInCoach(),
                                              rater: StandInRater(), language: "en") { _ in }
        XCTAssertEqual(records.count, 5)
        XCTAssertTrue(records.allSatisfy { $0.rating?.overall == 4 && $0.error == nil })
        let report = Autorater.report(records)
        XCTAssertTrue(report.contains("5/5 = 100.0 %"), report)
        XCTAssertTrue(report.contains("Critical safety issues: **0**"), report)
    }
}
