import XCTest
@testable import CoachAnalysis

/// Validation and the tool boundary: what a model gets back when it writes a spec wrong, and how the session
/// accounts for every test it runs.
final class AnalysisValidatorTests: XCTestCase {

    private let data = SyntheticWearer(days: 120, seed: 1).make()

    private func issues(_ spec: AnalysisSpec) -> [String] {
        AnalysisValidator.validate(spec, against: data).map(\.description)
    }

    func testUnknownMetricSuggestsTheClosestKeys() {
        let found = issues(AnalysisSpec(operation: .describe, windowDays: 30, metric: .init(series: "sleep_eff")))
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].hasPrefix("spec.metric.series unknown metric `sleep_eff`; closest: sleep_efficiency"),
                      found[0])
    }

    func testNightlySeriesMustStateItsAlignmentWhenAnchoredToDays() {
        let groups = [AnalysisSpec.Group(label: "Run", when: .init(event: .init(kind: "workout")))]
        let missing = issues(AnalysisSpec(operation: .compareGroups, windowDays: 90,
                                          metric: .init(series: "sleep_efficiency"), groups: groups))
        XCTAssertTrue(missing.contains { $0.contains("align is required for the nightly series") }, "\(missing)")

        let wrongKind = issues(AnalysisSpec(operation: .compareGroups, windowDays: 90,
                                            metric: .init(series: "hrv", align: .nightAfter), groups: groups))
        XCTAssertTrue(wrongKind.contains { $0.contains("hrv is a daily series: use same_day or next_day") }, "\(wrongKind)")

        // Describing a nightly series needs no anchor, so no alignment.
        XCTAssertEqual(issues(AnalysisSpec(operation: .describe, windowDays: 30, metric: .init(series: "sleep_efficiency"))), [])
    }

    func testOperationSpecificRequirements() {
        XCTAssertTrue(issues(AnalysisSpec(operation: .correlate, windowDays: 90, metric: .init(series: "hrv", align: .sameDay)))
            .contains("spec.metric2 is required for correlate"))
        XCTAssertTrue(issues(AnalysisSpec(operation: .rankDays, windowDays: 90, metric: .init(series: "hrv")))
            .contains { $0.hasPrefix("spec.order is required") })
        XCTAssertTrue(issues(AnalysisSpec(operation: .describe, windowDays: 4_000, metric: .init(series: "hrv")))
            .contains { $0.hasPrefix("spec.window_days must be between 7 and 3650") })
        let overlapping = AnalysisSpec(operation: .comparePeriods, windowDays: 90, metric: .init(series: "hrv"),
                                       periods: [.init(fromDaysAgo: 20, toDaysAgo: 0), .init(fromDaysAgo: 40, toDaysAgo: 10)])
        XCTAssertTrue(issues(overlapping).contains("spec.periods must not overlap"))
        let badCategory = AnalysisSpec(operation: .eventResponse, windowDays: 90, metric: .init(series: "hrv", align: .nextDay),
                                       event: .init(kind: "workout", categories: ["runing"]))
        XCTAssertTrue(issues(badCategory).contains { $0.contains("unknown category `runing`; closest: running") })
    }

    // MARK: - Tool boundary

    func testToolInputDecodesSnakeCaseAndReportsBadEnumsUsefully() {
        let session = AnalysisSession(dataset: data)
        let ok = session.handleToolCall([
            "plan": "Is my HRV different on days after hard days?",
            "spec": [
                "operation": "compare_groups", "window_days": 120,
                "metric": ["series": "hrv", "align": "next_day"],
                "groups": [["label": "Hard", "when": ["threshold": ["series": "strain", "gte": 12]]]],
            ],
        ])
        XCTAssertTrue(ok.hasPrefix("ANALYSIS #1 — compare_groups"), ok)

        let badEnum = session.handleToolCall([
            "plan": "x",
            "spec": ["operation": "compare", "window_days": 30, "metric": ["series": "hrv"]],
        ])
        XCTAssertTrue(badEnum.contains("spec.operation must be one of: describe, trend, compare_periods"), badEnum)

        let noPlan = session.handleToolCall(["spec": ["operation": "describe"]])
        XCTAssertTrue(noPlan.contains("plan is required"), noPlan)
        XCTAssertEqual(session.runs.count, 1, "failed calls are not runs")
    }

    func testEveryTestInAnAnswerIsCountedAndCorrected() {
        let session = AnalysisSession(dataset: SyntheticWearer(seed: 3, eveningEffect: 4).make())
        let evening = AnalysisSpec.Group(label: "Evening", when: .init(event: .init(kind: "workout", startHourGte: 18)))
        _ = session.run(AnalysisSpec(operation: .compareGroups, windowDays: 365,
                                     metric: .init(series: "sleep_efficiency", align: .nightAfter), groups: [evening]),
                        plan: "evening vs other days")
        let second = session.run(AnalysisSpec(operation: .trend, windowDays: 365, metric: .init(series: "hrv")),
                                 plan: "hrv trend")
        XCTAssertEqual(session.tests.count, 2)
        XCTAssertTrue(second.contains("Analyses in this answer so far: 2, statistical tests: 2."), second)
        XCTAssertTrue(second.contains("Updated q for every test in this answer: T1 q"), second)
        XCTAssertEqual(session.qValues.count, 2)
        for (q, test) in zip(session.qValues, session.tests) { XCTAssertGreaterThanOrEqual(q, test.p) }
    }

    func testVerdictWordingNeverClaimsAbsence() {
        let test = AnalysisTest(label: "x", estimate: 0.1, lower: -1, upper: 1, p: 0.6, n: 40, effectSize: nil, inMetricUnit: true)
        let text = AnalysisSession.verdict(test, q: 0.6, testCount: 1, operation: .compareGroups)
        XCTAssertTrue(text.hasPrefix("no reliable difference"))
        XCTAssertTrue(text.contains("not proof that there is none"))
        let suggestive = AnalysisTest(label: "x", estimate: 1, lower: 0.1, upper: 2, p: 0.03, n: 40, effectSize: nil, inMetricUnit: true)
        XCTAssertTrue(AnalysisSession.verdict(suggestive, q: 0.09, testCount: 3, operation: .compareGroups)
            .hasPrefix("suggestive only"))
    }

    // MARK: - Schema

    func testSchemaIsSerialisableAndConstrainedToTheDataset() throws {
        let schema = AnalysisToolSchema.inputSchema(for: data)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(schema))
        let json = String(data: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""enum":["hrv","sleep_efficiency","strain"]"#), "metric keys are enumerated")
        XCTAssertTrue(json.contains(#""enum":["alcohol"]"#), "tags are enumerated")
        XCTAssertFalse(json.contains("$ref") || json.contains("oneOf") || json.contains("additionalProperties"),
                       "stay inside the subset every provider accepts")
    }
}
