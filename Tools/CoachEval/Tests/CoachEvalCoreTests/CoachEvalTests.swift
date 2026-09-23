import XCTest
import CoachAnalysis
@testable import CoachEvalCore

final class CoachEvalTests: XCTestCase {

    private static let cohort = SyntheticCohort.make()
    private static let questions = QuestionBank.all(cohort: cohort)

    // MARK: - The oracle: reference, executor and scorer agree

    func testEveryReferenceSpecIsScoredCorrect() {
        let results = Runner.oracle(Self.questions, cohort: Self.cohort)
        let failures = results.filter { !$0.2 }.map { "\($0.0.id): expected \($0.0.expected)\n\($0.1)" }
        XCTAssertGreaterThanOrEqual(results.count, 250)
        XCTAssertTrue(failures.isEmpty, failures.prefix(3).joined(separator: "\n\n"))
    }

    /// The negative control. A result text holds many numbers (means, bounds, n), so a scorer that accepts
    /// "any number within tolerance" could pass by coincidence. Shift every expected value well outside its
    /// tolerance: nearly all must now fail, or the oracle above proves nothing.
    func testTheScorerRejectsWrongAnswers() {
        let results = Runner.oracle(Self.questions, cohort: Self.cohort)
        var checked = 0, falselyAccepted = 0
        for (question, text, _) in results {
            let wrong: Expected
            switch question.expected {
            case .number(let value, let tolerance, let signAgnostic):
                wrong = .number(value + (value >= 0 ? 1 : -1) * max(4 * tolerance, abs(value) * 0.25),
                                tolerance: tolerance, signAgnostic: signAgnostic)
            case .integer(let value):
                wrong = .integer(value + 3)
            case .day(let key):
                wrong = .day(DayKey.adding(2, to: key)!)
            }
            checked += 1
            if Scorer.isCorrect(text, wrong) { falselyAccepted += 1 }
        }
        print("negative control: \(falselyAccepted) of \(checked) wrong expectations accepted")
        XCTAssertLessThanOrEqual(Double(falselyAccepted) / Double(checked), 0.05,
                                 "\(falselyAccepted) of \(checked) wrong expectations were accepted")
    }

    // MARK: - Cohort

    func testCohortIsDeterministicAndItsEffectsVary() {
        let again = SyntheticCohort.make()
        XCTAssertEqual(again.map(\.effects), Self.cohort.map(\.effects))
        XCTAssertEqual(again[4].dataset.series["hrv"]?.values, Self.cohort[4].dataset.series["hrv"]?.values)
        // Every injected effect takes at least three sizes across the cohort, zero among them.
        XCTAssertEqual(Set(Self.cohort.map(\.effects.eveningWorkoutEfficiency)), [0, 2, 5])
        XCTAssertEqual(Set(Self.cohort.map(\.effects.alcoholHrv)), [0, -4, -9])
        XCTAssertEqual(Set(Self.cohort.map(\.effects.weekendSleepMin)), [0, 25, 45])
    }

    func testInjectedEffectsAreWhatTheReferenceMeasures() {
        // Across the cohort, the reference differences must follow the injected sizes: the bigger the
        // injected effect, the bigger the measured one. Checked as rank agreement, not equality.
        let pairs = Self.cohort.map { wearer -> (Double, Double) in
            let q = Self.questions.first { $0.wearer == wearer.id && $0.template == "weekend-sleep" }!
            guard case .number(let measured, _, _) = q.expected else { return (0, 0) }
            return (wearer.effects.weekendSleepMin, measured)
        }
        XCTAssertGreaterThan(AnalysisStatistics.spearman(pairs.map(\.0), pairs.map(\.1)) ?? 0, 0.8)
    }

    func testSmokeSetIsThirtyQuestionsAcrossFamiliesAndWearers() {
        let smoke = QuestionBank.smoke(from: Self.questions)
        XCTAssertEqual(smoke.count, 30)
        let families = Set(smoke.map { $0.template.split(separator: "-").first! })
        XCTAssertEqual(families.count, 9)
        XCTAssertGreaterThanOrEqual(Set(smoke.map(\.wearer)).count, 6)
        XCTAssertEqual(smoke.map(\.id), QuestionBank.smoke(from: Self.questions).map(\.id), "fixed forever")
    }

    // MARK: - Scorer

    func testNumbersAreReadInBothLanguages() {
        XCTAssertTrue(Scorer.numbers(in: "Deine HRV lag bei 2,9 ms").contains(2.9))
        XCTAssertTrue(Scorer.numbers(in: "about 8,123 steps").contains(8123))
        XCTAssertTrue(Scorer.numbers(in: "etwa 8.123 Schritte").contains(8123))
        XCTAssertTrue(Scorer.numbers(in: "a change of −4.5 ms").contains(-4.5))
        XCTAssertFalse(Scorer.numbers(in: "a 7-day mean").contains(-7), "a hyphen is not a minus sign")
        XCTAssertEqual(Scorer.numbers(in: "am 3.9. und am 2026-07-26"), [], "dates are not quantities")
        XCTAssertTrue(Scorer.numbers(in: "um 3.9 ms").contains(3.9), "a decimal without a trailing dot stays")
    }

    func testSignAgnosticNumbersAcceptDirectionInWords() {
        XCTAssertTrue(Scorer.isCorrect("HRV is 8.7 ms lower after alcohol", .number(-8.72, tolerance: 0.051, signAgnostic: true)))
        XCTAssertFalse(Scorer.isCorrect("HRV is 8.7 ms lower", .number(-8.72, tolerance: 0.051, signAgnostic: false)))
        XCTAssertFalse(Scorer.isCorrect("HRV is about 9 ms lower", .number(-8.72, tolerance: 0.051, signAgnostic: true)),
                       "below 10, rounding to a whole number loses the answer")
        XCTAssertTrue(Scorer.isCorrect("rho = 0.31", .number(0.305, tolerance: 0.011, signAgnostic: false)))
    }

    func testDaysAreMatchedInWrittenFormsButNotInsideOtherDays() {
        XCTAssertTrue(Scorer.isCorrect("Your best night was on 3 September.", .day("2026-09-03")))
        XCTAssertTrue(Scorer.isCorrect("Am 3. September war deine HRV am höchsten.", .day("2026-09-03")))
        XCTAssertTrue(Scorer.isCorrect("on Sep 3", .day("2026-09-03")))
        XCTAssertTrue(Scorer.isCorrect("am 03.09.", .day("2026-09-03")))
        XCTAssertFalse(Scorer.isCorrect("on 13 September", .day("2026-09-03")))
        XCTAssertFalse(Scorer.isCorrect("am 13.9.", .day("2026-09-03")))
    }
}
