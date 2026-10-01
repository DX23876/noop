import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class EnergyPlanNutritionTests: XCTestCase {
    private func makeRepo() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        return (repo, store)
    }

    func testManualAggregateIsReadBackWithOptionalMacros() async throws {
        let (repo, _) = try await makeRepo()
        let entry = ManualNutritionEntry(day: "2026-09-30", calories: 2_150,
                                         proteinG: 165, carbsG: 210, fatG: nil,
                                         isConfirmedNoIntake: false)
        let saved = await repo.recordManualNutrition(entry)
        let readback = await repo.manualNutrition(on: entry.day)
        XCTAssertTrue(saved)
        XCTAssertEqual(readback, entry)
    }

    func testManualCaloriesOverrideHealthWithoutErasingHealthMacros() async throws {
        let (repo, store) = try await makeRepo()
        let day = "2026-09-30"
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day, key: EnergyPlanStore.caloriesKey, value: 2_000),
            MetricPoint(day: day, key: EnergyPlanStore.proteinKey, value: 140),
            MetricPoint(day: day, key: EnergyPlanStore.carbsKey, value: 220),
            MetricPoint(day: day, key: EnergyPlanStore.fatKey, value: 70),
        ], deviceId: Repository.appleHealthSource)
        let saved = await repo.recordManualNutrition(.init(
            day: day, calories: 2_250, proteinG: nil, carbsG: nil, fatG: nil,
            isConfirmedNoIntake: false))
        XCTAssertTrue(saved)

        let resolved = await repo.nutritionByDay(from: day, to: day)[day]
        XCTAssertEqual(resolved?.calories, 2_250)
        XCTAssertEqual(resolved?.caloriesSource, .manual)
        XCTAssertEqual(resolved?.proteinG, 140)
        XCTAssertEqual(resolved?.carbsG, 220)
        XCTAssertEqual(resolved?.fatG, 70)
        XCTAssertEqual(resolved?.macrosSource, .appleHealth)
    }

    func testConfirmedZeroIsDifferentFromUnknownAndCanBeRemoved() async throws {
        let (repo, store) = try await makeRepo()
        let day = "2026-09-30"
        let initially = await repo.nutritionByDay(from: day, to: day)[day]
        XCTAssertNil(initially)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day, key: EnergyPlanStore.caloriesKey, value: 1_800),
            MetricPoint(day: day, key: EnergyPlanStore.proteinKey, value: 130),
        ], deviceId: Repository.appleHealthSource)
        let saved = await repo.recordManualNutrition(.init(
            day: day, calories: 0, proteinG: nil, carbsG: nil, fatG: nil,
            isConfirmedNoIntake: true))
        XCTAssertTrue(saved)
        let zero = await repo.nutritionByDay(from: day, to: day)[day]
        XCTAssertEqual(zero?.calories, 0)
        XCTAssertEqual(zero?.caloriesSource, .manual)
        XCTAssertEqual(zero?.isConfirmedNoIntake, true)

        let deleted = await repo.deleteIntake(on: day)
        let afterDelete = await repo.nutritionByDay(from: day, to: day)[day]
        XCTAssertTrue(deleted)
        XCTAssertEqual(afterDelete?.calories, 1_800)
        XCTAssertEqual(afterDelete?.caloriesSource, .appleHealth)
        XCTAssertEqual(afterDelete?.proteinG, 130)
        XCTAssertEqual(afterDelete?.isConfirmedNoIntake, false)
    }

    func testManualThenCsvThenHealthPrecedenceIsAppliedPerField() async throws {
        let (repo, store) = try await makeRepo()
        let day = "2026-09-30"
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day, key: EnergyPlanStore.caloriesKey, value: 2_000),
            MetricPoint(day: day, key: EnergyPlanStore.proteinKey, value: 140),
            MetricPoint(day: day, key: EnergyPlanStore.carbsKey, value: 220),
            MetricPoint(day: day, key: EnergyPlanStore.fatKey, value: 70),
        ], deviceId: Repository.appleHealthSource)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day, key: EnergyPlanStore.caloriesKey, value: 2_100),
            MetricPoint(day: day, key: EnergyPlanStore.carbsKey, value: 230),
        ], deviceId: EnergyPlanStore.csvIntakeSource)
        let saved = await repo.recordManualNutrition(.init(
            day: day, calories: 2_200, proteinG: 160, carbsG: nil, fatG: nil,
            isConfirmedNoIntake: false))
        XCTAssertTrue(saved)

        let resolved = await repo.nutritionByDay(from: day, to: day)[day]
        XCTAssertEqual(resolved?.calories, 2_200)
        XCTAssertEqual(resolved?.proteinG, 160)
        XCTAssertEqual(resolved?.carbsG, 230)
        XCTAssertEqual(resolved?.fatG, 70)
    }

    func testConfirmedZeroRejectsContradictoryMacros() async throws {
        let (repo, _) = try await makeRepo()
        let saved = await repo.recordManualNutrition(.init(
            day: "2026-09-30", calories: 0, proteinG: 10, carbsG: nil, fatG: nil,
            isConfirmedNoIntake: true))
        XCTAssertFalse(saved)
    }

    func testInvalidManualEntryIsRejectedWithoutReplacingSavedValue() async throws {
        let (repo, _) = try await makeRepo()
        let day = "2026-09-30"
        let original = ManualNutritionEntry(day: day, calories: 1_900,
                                            proteinG: nil, carbsG: nil, fatG: nil,
                                            isConfirmedNoIntake: false)
        let originalSaved = await repo.recordManualNutrition(original)
        let invalidSaved = await repo.recordManualNutrition(.init(
            day: day, calories: -1, proteinG: nil, carbsG: nil, fatG: nil,
            isConfirmedNoIntake: false))
        let readback = await repo.manualNutrition(on: day)
        XCTAssertTrue(originalSaved)
        XCTAssertFalse(invalidSaved)
        XCTAssertEqual(readback, original)
    }
}
