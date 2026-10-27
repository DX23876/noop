import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

@MainActor
final class CoreGoalEnergyTests: XCTestCase {
    func testRecordedActiveEnergyFeedsTheDailyAndWeeklyGoal() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        let now = Date(), today = StoreReader.localDayKey(now)
        _ = try await store.upsertAppleDaily([.init(day: today, steps: nil, activeKcal: 650, basalKcal: 1800,
            vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)], deviceId: "apple-health")
        var settings = CoreGoals.Settings(profileSex: "male", lastSync: nil, agelessEnabled: false,
                                           dismissedWorkoutSpans: [])
        settings.energyProfile = .init(weightKg: 80, heightCm: 180, age: 40, sex: "male", maxHR: 180,
                                       basalFormula: .mifflinStJeor)
        try await CoreGoalState.change(store: store) { context in
            context.actions.upsert(GoalAction(title: "Move", requirement: .activeCalories(minimum: 500),
                goalIds: [], createdAt: now.addingTimeInterval(-86400)))
        }
        let added = await CoreGoals.addPeriodGoal(store: store, metric: "activeEnergy", period: "week", target: 3000,
                                                  threshold: nil, now: now)
        XCTAssertTrue(added.ok)
        let setup = try await CoreGoals.setup(reader: reader, settings: settings, now: now)
        XCTAssertEqual(setup.metrics.first { $0.metric == "activeEnergy" }?.available, true)
        let output = try await CoreGoals.snapshot(reader: reader, settings: settings, now: now)
        let daily = try XCTUnwrap(output.today.first { $0.kind == "activeCalories" })
        XCTAssertEqual(daily.measured, 650)
        XCTAssertTrue(daily.isCompleted)
        XCTAssertEqual(output.period.first { $0.metric == "activeEnergy" }?.current, 650)
    }

    func testProfileWireUsesTheAppleDefaultFormulaAndRejectsMissingBodyInputs() {
        let values: [String: Any] = ["sex": "female", "energyProfile": ["weightKg": 65, "heightCm": 170,
            "age": 35, "maxHR": 180]]
        let parsed = CoreGoalEnergy.settings(values)
        XCTAssertEqual(parsed.energyProfile?.weightKg, 65)
        XCTAssertEqual(parsed.energyProfile?.basalFormula, .mifflinStJeor)
        XCTAssertNil(CoreGoalEnergy.settings(["sex": "female"]).energyProfile)
        XCTAssertNil(CoreGoalEnergy.settings(["energyProfile": ["weightKg": -1, "heightCm": 170,
            "age": 35, "maxHR": 180]]).energyProfile)
    }

    func testAnalysisAndGoalReadersReceiveTheSameFormulaSelection() throws {
        let json = #"{"formulaLog":"[{\"effectiveFrom\":\"0000-01-01\",\"formula\":\"revisedHarrisBenedict\"},{\"effectiveFrom\":\"2026-10-01\",\"formula\":\"katchMcArdle\"}]"}"#
        var analysis = CoreAnalysis.Settings.standard
        var profile = CoreAnalysis.Profile(age: 40, sex: "male", weightKg: 80, heightCm: 180, hrMaxOverride: 180)
        XCTAssertEqual(analysis.basalFormula, .mifflinStJeor)
        CoreAnalysis.applyExtras(json, to: &analysis, profile: &profile)
        XCTAssertEqual(analysis.basalFormula, .katchMcArdle)
        var args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        args["sex"] = "male"
        args["energyProfile"] = ["weightKg": 80, "heightCm": 180, "age": 40, "maxHR": 180]
        XCTAssertEqual(CoreGoalEnergy.settings(args).energyProfile?.basalFormula, analysis.basalFormula)
    }

}
