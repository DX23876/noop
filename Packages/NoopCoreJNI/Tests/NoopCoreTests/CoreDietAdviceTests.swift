import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The plan page's suggestions on Android (`food.planAdvice`, `food.planApplyAdvice`): the shared `DietAdvice` over the
/// stored weigh-ins and food log, without what was dismissed this week, and the plan a suggestion changes.
@MainActor
final class CoreDietAdviceTests: XCTestCase {
    func testFewWeighInsAndLogsAskForMoreAndADismissalHoldsForTheWeek() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let now = Date()
        for (daysAgo, kg) in [(30, 100.0), (20, 99.0), (10, 98.0), (2, 97.5)] {
            let weighed = await CoreBody.logWeight(store: store, kg: kg, at: now.addingTimeInterval(-Double(daysAgo) * 86_400), note: nil)
            XCTAssertTrue(weighed)
        }
        let start = StoreReader.localDayKey(now.addingTimeInterval(-35 * 86_400))
        let plan = DietPlan(goal: .lose, pacePercent: 0.5, form: .balanced, goalWeightKg: 90, startDay: start, startWeightKg: 100)
        var args: [String: Any] = ["plan": plan.encoded() ?? "", "weightKg": 97.5, "heightCm": 180.0, "age": 40, "sex": "male"]
        func kinds() async throws -> [String] {
            let json = await CoreDietPlan.run("food.planAdvice", args: args, store: store, reader: reader)
            let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(o["week"] as? String, CoreDietPlan.adviceWeek)
            return (o["suggestions"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        }
        let first = try await kinds()
        XCTAssertEqual(first, ["weighMore", "logMore"])
        args["dismissed"] = [CoreDietPlan.adviceWeek + ":weighMore", "2000-01-03:logMore"]
        let second = try await kinds()
        XCTAssertEqual(second, ["logMore"])
    }

    func testABreakWeekStartsTodayAndAPageSuggestionChangesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let plan = DietPlan(goal: .lose, pacePercent: 0.5, form: .balanced, goalWeightKg: 90, startDay: "2026-01-01", startWeightKg: 100)
        let taken = await CoreDietPlan.run("food.planApplyAdvice",
                                           args: ["plan": plan.encoded() ?? "", "kind": "lossStalled", "action": "takeBreakWeek"],
                                           store: store, reader: reader)
        XCTAssertEqual(DietPlan.decode(taken)?.breakFromDay, StoreReader.localDayKey(Date()))
        let page = await CoreDietPlan.run("food.planApplyAdvice",
                                          args: ["plan": plan.encoded() ?? "", "kind": "proteinLow", "action": "showProteinFoods"],
                                          store: store, reader: reader)
        XCTAssertEqual(page, "null")
    }
}
