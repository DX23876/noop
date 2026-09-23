import XCTest
@testable import CoachAnalysis

/// The executor against a synthetic wearer with KNOWN effects. A method is only trusted if it recovers
/// several injected sizes (including zero), not one lucky match.
final class AnalysisExecutorTests: XCTestCase {

    private let eveningVsMorning: [AnalysisSpec.Group] = [
        .init(label: "Evening", when: .init(event: .init(kind: "workout", startHourGte: 18))),
        .init(label: "Morning", when: .init(event: .init(kind: "workout", startHourLt: 12))),
    ]

    private func eveningComparison(align: AnalysisSpec.Align = .nightAfter, window: Int = 365) -> AnalysisSpec {
        AnalysisSpec(operation: .compareGroups, windowDays: window,
                     metric: .init(series: "sleep_efficiency", align: align), groups: eveningVsMorning)
    }

    private func firstTest(_ spec: AnalysisSpec, _ data: AnalysisDataset) -> AnalysisTest? {
        XCTAssertEqual(AnalysisValidator.validate(spec, against: data), [])
        return AnalysisExecutor(data: data).run(spec, plan: "test").tests.first
    }

    // MARK: - Recovering injected effects

    func testCompareGroupsRecoversSeveralInjectedEffectSizes() throws {
        // Across 12 synthetic wearers per size, the 95 % interval should cover the true difference in the
        // large majority, and a real effect should be detected while a null one mostly should not.
        for effect in [0.0, 1.5, 4.0] {
            var covered = 0, detected = 0
            let wearers = 12
            for seed in 1...UInt64(wearers) {
                let data = SyntheticWearer(seed: seed, eveningEffect: effect).make()
                let test = try XCTUnwrap(firstTest(eveningComparison(), data))
                if test.lower <= -effect && -effect <= test.upper { covered += 1 }
                if test.p < 0.05 { detected += 1 }
            }
            XCTAssertGreaterThanOrEqual(covered, 10, "interval coverage for an effect of \(effect)")
            if effect == 0 {
                XCTAssertLessThanOrEqual(detected, 2, "false positives with no effect")
            } else if effect >= 4 {
                XCTAssertEqual(detected, wearers, "a 4-point effect should always be found over a year")
            }
        }
    }

    func testAlignmentPinsTheNightAfterNotTheNightBefore() throws {
        // The effect lives only in the night that STARTS on the workout evening. Reading the night that
        // ended that morning must not find it; reading the night after must.
        let data = SyntheticWearer(seed: 7, eveningEffect: 5).make()
        let after = try XCTUnwrap(firstTest(eveningComparison(align: .nightAfter), data))
        let before = try XCTUnwrap(firstTest(eveningComparison(align: .nightBefore), data))
        XCTAssertEqual(after.estimate, -5, accuracy: 1.5)
        XCTAssertLessThan(after.p, 0.01)
        XCTAssertEqual(before.estimate, 0, accuracy: 1.5)
    }

    func testTrendRecoversTheInjectedSlope() throws {
        for slope in [0.0, 1.0, 3.0] {
            let data = SyntheticWearer(seed: 3, hrvTrendPer30: slope).make()
            let spec = AnalysisSpec(operation: .trend, windowDays: 365, metric: .init(series: "hrv"))
            let test = try XCTUnwrap(firstTest(spec, data))
            XCTAssertEqual(test.estimate, slope, accuracy: 0.6, "slope \(slope) per 30 days")
            XCTAssertTrue(test.lower <= slope && slope <= test.upper)
        }
    }

    func testCorrelateFindsTheCouplingAtItsLagOnly() throws {
        let data = SyntheticWearer(seed: 11, lagCoupling: 1.2).make()
        func rho(lag: Int) throws -> AnalysisTest {
            let spec = AnalysisSpec(operation: .correlate, windowDays: 365, metric: .init(series: "strain", align: .sameDay),
                                    metric2: .init(series: "hrv", align: .sameDay), lagDays: lag)
            return try XCTUnwrap(firstTest(spec, data))
        }
        let lagged = try rho(lag: 1)
        let sameDay = try rho(lag: 0)
        XCTAssertGreaterThan(lagged.estimate, 0.3)
        XCTAssertLessThan(lagged.p, 0.01)
        XCTAssertEqual(sameDay.estimate, 0, accuracy: 0.15)
    }

    func testEventResponseSeparatesTheNightAfterFromLaterNights() throws {
        let data = SyntheticWearer(seed: 5, eveningEffect: 4).make()
        let spec = AnalysisSpec(operation: .eventResponse, windowDays: 365,
                                metric: .init(series: "sleep_efficiency", align: .nightAfter),
                                event: .init(kind: "workout", startHourGte: 18), responseDays: 2)
        let tests = AnalysisExecutor(data: data).run(spec, plan: "test").tests
        XCTAssertEqual(tests.count, 2, "one test per followed day")
        XCTAssertEqual(tests[0].estimate, -4, accuracy: 1.5)
        XCTAssertEqual(tests[1].estimate, 0, accuracy: 1.5, "the effect is gone the next night")
    }

    // MARK: - Honesty

    func testTooFewDaysIsReportedNotComputed() {
        let data = SyntheticWearer(days: 20, seed: 2, workoutRate: 0.2).make()
        let result = AnalysisExecutor(data: data).run(eveningComparison(window: 20), plan: "test")
        XCTAssertTrue(result.tests.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("Too few days") })
    }

    func testConfoundersAreNamed() {
        let data = SyntheticWearer(seed: 9, eveningEffect: 3, eveningStrainBoost: 4).make()
        let result = AnalysisExecutor(data: data).run(eveningComparison(), plan: "test")
        XCTAssertTrue(result.confounders.contains { $0.contains("higher strain") }, "\(result.confounders)")
    }

    func testUnansweredTagDaysAreNeitherYesNorNo() {
        let data = SyntheticWearer(seed: 4, alcoholAnswerRate: 0.5, alcoholEffect: 3).make()
        let spec = AnalysisSpec(operation: .compareGroups, windowDays: 365,
                                metric: .init(series: "sleep_efficiency", align: .nightAfter),
                                groups: [.init(label: "Alcohol", when: .init(tag: "alcohol")),
                                         .init(label: "No alcohol", when: .init(tag: "alcohol", tagValue: false))])
        let result = AnalysisExecutor(data: data).run(spec, plan: "test")
        let tag = data.tags["alcohol"]!
        let counted = result.tests.first!.n
        XCTAssertLessThanOrEqual(counted, tag.answered.count, "only answered days can be in either group")
        XCTAssertEqual(result.tests.first!.estimate, -3, accuracy: 1.5)
    }

    func testOnlyRankDaysEverListsIndividualDays() {
        let data = SyntheticWearer(seed: 6, eveningEffect: 2).make()
        let session = AnalysisSession(dataset: data)
        let text = session.run(eveningComparison(), plan: "compare")
        let dayPattern = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
        let days = dayPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertEqual(days, 2, "only the window bounds: \(text)")

        let rank = session.run(AnalysisSpec(operation: .rankDays, windowDays: 90, metric: .init(series: "hrv"),
                                            order: .highest, limit: 9), plan: "best days")
        let listed = dayPattern.numberOfMatches(in: rank, range: NSRange(rank.startIndex..., in: rank))
        XCTAssertEqual(listed, 0, "limit 9 is refused by validation, so nothing is listed: \(rank)")
        XCTAssertTrue(rank.hasPrefix("ANALYSIS NOT RUN"))

        let five = session.run(AnalysisSpec(operation: .rankDays, windowDays: 90, metric: .init(series: "hrv"),
                                            order: .highest, limit: 5), plan: "best days")
        XCTAssertEqual(dayPattern.numberOfMatches(in: five, range: NSRange(five.startIndex..., in: five)), 2 + 5)
    }

    func testTransformsNeedEnoughHistory() {
        let data = SyntheticWearer(days: 30, seed: 8).make()
        let executor = AnalysisExecutor(data: data)
        let today = DayKey.ordinal(data.today)!
        XCTAssertNotNil(executor.value(.init(series: "hrv", transform: .rollingMean7), at: today))
        XCTAssertNotNil(executor.value(.init(series: "hrv", transform: .deltaFromBaseline), at: today))
        XCTAssertNil(executor.value(.init(series: "hrv", transform: .deltaFromBaseline), at: today - 20),
                     "fewer than 14 prior days")
        XCTAssertNil(executor.value(.init(series: "sleep_efficiency", align: .nightAfter), at: today),
                     "tonight has not happened yet")
    }
}
