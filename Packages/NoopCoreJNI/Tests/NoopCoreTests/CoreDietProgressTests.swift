import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// Today's diet goal card on Android: the way to the goal weight comes from the shared `DietProgress` over the
/// stored weigh-ins, and a plan that hides its numbers keeps the card empty.
@MainActor
final class CoreDietProgressTests: XCTestCase {
    func testTheWayToTheGoalReadsTheStoredWeighIns() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let now = Date()
        for (daysAgo, kg) in [(20, 100.0), (14, 98.5), (7, 97.5), (1, 96.0)] {
            let weighed = await CoreBody.logWeight(store: store, kg: kg, at: now.addingTimeInterval(-Double(daysAgo) * 86_400), note: nil)
            XCTAssertTrue(weighed)
        }
        let start = StoreReader.localDayKey(now.addingTimeInterval(-21 * 86_400))
        var plan = DietPlan(goal: .lose, pacePercent: 0.5, form: .balanced, goalWeightKg: 90, startDay: start, startWeightKg: 100)
        let args: [String: Any] = ["plan": plan.encoded() ?? "", "weightKg": 96.0, "heightCm": 180.0, "age": 40, "sex": "male"]
        let json = await CoreDietPlan.run("food.planProgress", args: args, store: store, reader: reader)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(o["kind"] as? String, "way")
        XCTAssertEqual(o["goalKg"] as? Double, 90)
        let fraction = try XCTUnwrap(o["fraction"] as? Double)
        XCTAssertGreaterThan(fraction, 0.2)
        XCTAssertLessThan(fraction, 0.6)

        plan.hideNumbers = true
        let hidden = await CoreDietPlan.run("food.planProgress", args: ["plan": plan.encoded() ?? ""], store: store, reader: reader)
        XCTAssertEqual(hidden, "null")
    }
}
