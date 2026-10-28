import Foundation
import XCTest
import StrandAnalytics
import WhoopStore
@testable import StrandCore

final class EnergySummaryPreparationTests: XCTestCase {
    private let today = "2026-10-27", yesterday = "2026-10-26"
    private var now: Date { WeightSeries.date(forDay: today)! }
    private var profile: UserProfile { .init(weightKg: 90, heightCm: 180, age: 40, sex: "male", maxHR: 180) }
    private func inputs() -> EnergySummaryPreparation.Inputs {
        .init(appleByDay: [:], strapByDay: [:], derivedByDay: [:], strapActiveByDay: [:],
            stepHoursByDay: [:], sessionsByDay: [:], weightObservations: [], calibrationStatus: .off,
            calibrationFactor: nil, shape: nil, adaptivePrior: nil, appleCoverageByDay: [:],
            stride: StepLengthTimeline(samplesByDay: [:]))
    }
    private func daily(_ day: String, kcal: Double?) -> DailyMetric {
        .init(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 55, avgHrv: nil, recovery: nil, strain: nil,
            exerciseCount: nil, activeKcalEst: kcal, energyCoverageSeconds: 86_400)
    }
    private func summaries(_ inputs: EnergySummaryPreparation.Inputs) -> [DailyEnergySummary] {
        EnergySummaryPreparation.summaries(inputs, profile: profile, hrMax: 180, now: now, bodyFatOn: { _ in nil })
    }

    func testEmptySourcesKeepTodayHonestWithoutInventingAnEnergyMeasurement() throws {
        let rows = summaries(inputs())
        XCTAssertEqual(rows.map(\.day), [today])
        XCTAssertEqual(rows[0].source, .profileOnly)
        XCTAssertNil(rows[0].activeBurnedSoFar)
        XCTAssertNil(rows[0].totalBurnedSoFar)
        XCTAssertNotNil(rows[0].estimatedBMR24h)
    }

    func testCurrentDerivedActiveEnergyStaysWithItsOwnModelCoverage() throws {
        var source = inputs()
        source.strapByDay[today] = daily(today, kcal: 3000)
        source.derivedByDay[today] = .init(day: today, rawTotalKcal: 1200,
            modelVersion: WhoopDailyEnergyEstimate.modelVersion, observedSeconds: 7200,
            inferredSeconds: 0, modeledSeconds: 0, uncertaintyFraction: 0.2,
            weightKg: 90, weightSource: .profile)
        source.strapActiveByDay[today] = 400
        let row = try XCTUnwrap(summaries(source).first { $0.day == today })
        XCTAssertEqual(row.activeBurnedSoFar, 400)
        XCTAssertEqual(row.rawWhoopTotalKcal, 1200)
    }

    func testLegacyWholeDayEnergyIsNotPresentedAsTodaysMeasurement() throws {
        var source = inputs()
        source.strapByDay[today] = daily(today, kcal: 2400)
        source.strapByDay[yesterday] = daily(yesterday, kcal: 2400)
        let rows = summaries(source)
        let current = try XCTUnwrap(rows.first { $0.day == today })
        let past = try XCTUnwrap(rows.first { $0.day == yesterday })
        XCTAssertNil(current.activeBurnedSoFar)
        XCTAssertEqual(current.source, .profileOnly)
        XCTAssertNotNil(past.activeBurnedSoFar)
        XCTAssertEqual(past.rawWhoopTotalKcal, 2400)
        XCTAssertNil(past.projectedTotalBurn)
    }

    func testHistoricalBodyMassDoesNotReadAFutureWeighIn() throws {
        var source = inputs()
        source.strapByDay[yesterday] = daily(yesterday, kcal: nil)
        source.weightObservations = [
            .init(timestamp: Int(WeightSeries.date(forDay: yesterday)!.timeIntervalSince1970), weightKg: 70, source: .manual),
            .init(timestamp: Int(WeightSeries.date(forDay: today)!.timeIntervalSince1970), weightKg: 100, source: .manual)
        ]
        let past = try XCTUnwrap(summaries(source).first { $0.day == yesterday })
        var historical = profile
        historical.weightKg = 70
        XCTAssertEqual(past.estimatedBMR24h, Calories.bmrKcalPerDay(profile: historical))
    }

    func testForecastInputsDoNotChangeActiveEnergyUsedByGoals() throws {
        var source = inputs()
        source.appleByDay[today] = .init(day: today, steps: 9000, activeKcal: 650, basalKcal: 1800,
            vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
        let before = EnergySummaryPreparation.activeValues(summaries(source))
        source.adaptivePrior = 4500
        source.shape = .init(cumulativeByHour: (1...24).map { Double($0) / 24 }, sampleDays: 30,
            expectedActiveByHour: [Double](repeating: 80, count: 24))
        XCTAssertEqual(EnergySummaryPreparation.activeValues(summaries(source)), before)
    }

}
