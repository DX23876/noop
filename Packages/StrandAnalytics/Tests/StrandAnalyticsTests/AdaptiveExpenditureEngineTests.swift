import XCTest
@testable import StrandAnalytics

final class AdaptiveExpenditureEngineTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var asOf: Date { Date(timeIntervalSince1970: 1_800_057_600) }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo,
                      to: calendar.startOfDay(for: asOf))!
    }

    private func completeHistory(intake: (Int) -> Double = { _ in 2_500 },
                                 weight: (Int) -> Double = { _ in 80 })
        -> [AdaptiveExpenditureDay] {
        (1...35).map { ago in
            AdaptiveExpenditureDay(date: date(daysAgo: ago),
                                   caloriesIn: intake(ago), weightKg: weight(ago))
        }
    }

    func testStableWeightMakesExpenditureMatchIntake() throws {
        let result = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: completeHistory(), asOf: asOf, calendar: calendar))
        XCTAssertEqual(result.estimatedDailyKcal, 2_500, accuracy: 1)
        XCTAssertEqual(result.weightChangeKgPerDay, 0, accuracy: 0.0001)
        XCTAssertEqual(result.confidence, .high)
    }

    func testWeightLossRaisesExpenditureAboveIntake() throws {
        // Newer weights are lower by 0.05 kg/day: expenditure = 2,500 + 385.
        let result = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: completeHistory(weight: { ago in 80 + Double(ago) * 0.05 }),
            asOf: asOf, calendar: calendar))
        XCTAssertEqual(result.weightChangeKgPerDay, -0.05, accuracy: 0.012)
        XCTAssertEqual(result.estimatedDailyKcal, 2_885, accuracy: 95)
    }

    func testWeightGainLowersExpenditureBelowIntake() throws {
        let result = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: completeHistory(weight: { ago in 80 - Double(ago) * 0.03 }),
            asOf: asOf, calendar: calendar))
        XCTAssertGreaterThan(result.weightChangeKgPerDay, 0)
        XCTAssertLessThan(result.estimatedDailyKcal, result.averageCaloriesIn)
    }

    func testSparseIntakeDoesNotProduceEstimate() {
        let rows = (1...35).map { ago in
            AdaptiveExpenditureDay(date: date(daysAgo: ago),
                                   caloriesIn: ago.isMultiple(of: 2) ? 2_400 : nil,
                                   weightKg: 80)
        }
        XCTAssertNil(AdaptiveExpenditureEngine.estimate(days: rows, asOf: asOf,
                                                        calendar: calendar))
    }

    func testShortWindowDoesNotProduceEstimate() {
        let rows = (1...20).map {
            AdaptiveExpenditureDay(date: date(daysAgo: $0), caloriesIn: 2_400, weightKg: 80)
        }
        XCTAssertNil(AdaptiveExpenditureEngine.estimate(days: rows, asOf: asOf,
                                                        calendar: calendar))
    }

    func testIntakeOutlierIsTrimmed() throws {
        let result = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: completeHistory(intake: { $0 == 10 ? 7_500 : 2_500 }),
            asOf: asOf, calendar: calendar))
        XCTAssertEqual(result.averageCaloriesIn, 2_500, accuracy: 1)
    }

    func testSingleWeightOutlierDoesNotRewriteTrend() throws {
        let clean = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: completeHistory(weight: { ago in 80 + Double(ago) * 0.03 }),
            asOf: asOf, calendar: calendar))
        let noisy = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: completeHistory(weight: { ago in ago == 12 ? 92 : 80 + Double(ago) * 0.03 }),
            asOf: asOf, calendar: calendar))
        XCTAssertEqual(noisy.estimatedDailyKcal, clean.estimatedDailyKcal, accuracy: 25)
    }

    func testTodayAndFutureNeverLeakIntoEstimate() throws {
        var baseline = completeHistory()
        let expected = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: baseline, asOf: asOf, calendar: calendar))
        baseline.append(.init(date: date(daysAgo: 0), caloriesIn: 8_000, weightKg: 120))
        baseline.append(.init(date: calendar.date(byAdding: .day, value: 1, to: asOf)!,
                              caloriesIn: 8_000, weightKg: 120))
        let actual = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: baseline, asOf: asOf, calendar: calendar))
        XCTAssertEqual(actual, expected)
    }

    func testDuplicateDaysDoNotInflateCoverageOrChangeEstimate() throws {
        let baseline = completeHistory()
        let expected = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: baseline, asOf: asOf, calendar: calendar))
        let duplicates = baseline + baseline.map {
            AdaptiveExpenditureDay(date: $0.date, caloriesIn: $0.caloriesIn,
                                   weightKg: $0.weightKg)
        }
        let actual = try XCTUnwrap(AdaptiveExpenditureEngine.estimate(
            days: duplicates, asOf: asOf, calendar: calendar))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.intakeDays, 35)
        XCTAssertEqual(actual.weightReadings, 35)
    }

    func testImplausibleOutputIsWithheld() {
        let rows = completeHistory(intake: { _ in 6_000 },
                                   weight: { ago in 80 + Double(ago) * 0.2 })
        XCTAssertNil(AdaptiveExpenditureEngine.estimate(days: rows, asOf: asOf,
                                                        calendar: calendar))
    }
}
