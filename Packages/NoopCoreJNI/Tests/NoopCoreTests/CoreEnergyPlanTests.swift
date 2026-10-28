import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The Energy Plan on Android (parity plan 2.3): logged intake and the profile reach the shared formulas, and a
/// typed intake lands in the manual lane the balance reads.
@MainActor
final class CoreEnergyPlanTests: XCTestCase {
    func testPlanPricesTheFormulasAndRecordsTodaysIntake() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let settings = CoreGoalEnergy.settings(["sex": "male", "energyProfile":
            ["weightKg": 90.0, "heightCm": 180.0, "age": 40.0, "maxHR": 185.0]])
        let empty = await CoreEnergyPlan.plan(reader: reader, settings: CoreGoalEnergy.settings([:]),
                                              activity: .light, targetKgPerWeek: 0)
        XCTAssertFalse(empty.available)

        let recorded = await CoreEnergyPlan.recordIntake(store: store, kcal: 2_400)
        XCTAssertTrue(recorded)
        let plan = await CoreEnergyPlan.plan(reader: reader, settings: settings, activity: .moderate, targetKgPerWeek: -0.5)
        XCTAssertTrue(plan.available)
        XCTAssertEqual(plan.todayIntakeKcal, 2_400)
        XCTAssertEqual(plan.formulas.count, BasalFormula.allCases.count)
        XCTAssertEqual(plan.formulas.first { $0.formula == "katchMcArdle" }?.available, false)
        let basal = try XCTUnwrap(plan.formulas.first { $0.formula == plan.currentFormula }?.basalKcal)
        XCTAssertEqual(try XCTUnwrap(plan.formulaTdeeKcal), basal * ActivityLevel.moderate.factor, accuracy: 1)
        XCTAssertNotNil(plan.targetDailyKcal)
        let zero = await CoreEnergyPlan.recordIntake(store: store, kcal: 0)
        XCTAssertTrue(zero)
    }
}
