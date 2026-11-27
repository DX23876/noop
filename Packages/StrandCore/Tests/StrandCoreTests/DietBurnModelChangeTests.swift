import XCTest
@testable import StrandCore

/// A plan under a new strap energy model (owner decisions 2026-11-27, Q11, Q30): Forge's old adjustments start
/// from zero, the Food page gets one note with the change, and the weekly look holds two weeks.
final class DietBurnModelChangeTests: XCTestCase {
    private func plan(adjustment: Double = 0, steering: DietPlan.Steering = .coached,
                      burnSource: DietPlan.BurnSource? = nil) -> DietPlan {
        var plan = DietPlan(goal: .lose, pacePercent: 0.5, steering: steering, startDay: "2026-10-01",
                            startWeightKg: 200, adjustmentKcal: adjustment, burnSource: burnSource)
        plan.lastAdjustedDay = "2026-11-10"
        return plan
    }

    func testAPlanFromBeforeTheEverydayShareStartsAgainAndNotesTheChange() throws {
        let adopted = try XCTUnwrap(DietBurnModelChange.adopt(
            plan(adjustment: 150), current: "whoop-bucket-v10", everydayMeanKcal: 610, today: "2026-11-28"))
        XCTAssertEqual(adopted.adjustmentKcal, 0)
        XCTAssertEqual(adopted.burnModelVersion, "whoop-bucket-v10")
        XCTAssertEqual(adopted.burnModelChangedDay, "2026-11-28")
        XCTAssertEqual(try XCTUnwrap(adopted.burnModelNoteKcal), 610 - 150, accuracy: 1e-9)
    }

    func testAPlanAlreadyOnTheModelIsLeftAlone() {
        var current = plan(adjustment: 100)
        current.burnModelVersion = "whoop-bucket-v10"
        XCTAssertNil(DietBurnModelChange.adopt(current, current: "whoop-bucket-v10", everydayMeanKcal: 600,
                                               today: "2026-11-28"))
    }

    /// The scale's burn never came from the strap model, so its adjustments stand.
    func testAScaleBasedPlanKeepsItsAdjustments() throws {
        let adopted = try XCTUnwrap(DietBurnModelChange.adopt(
            plan(adjustment: 150, burnSource: .scale), current: "whoop-bucket-v10", everydayMeanKcal: 600,
            today: "2026-11-28"))
        XCTAssertEqual(adopted.adjustmentKcal, 150)
        XCTAssertNil(adopted.burnModelNoteKcal)
        XCTAssertNil(adopted.burnModelChangedDay)
        XCTAssertEqual(adopted.burnModelVersion, "whoop-bucket-v10")
    }

    func testASmallChangeIsNotWorthANote() throws {
        let adopted = try XCTUnwrap(DietBurnModelChange.adopt(
            plan(adjustment: 0), current: "whoop-bucket-v10", everydayMeanKcal: 10, today: "2026-11-28"))
        XCTAssertNil(adopted.burnModelNoteKcal)
    }

    func testTheWeeklyLookHoldsTwoWeeksAfterTheChange() throws {
        var adopted = try XCTUnwrap(DietBurnModelChange.adopt(
            plan(), current: "whoop-bucket-v10", everydayMeanKcal: 600, today: "2026-11-28"))
        adopted.lastAdjustedDay = "2026-11-01"
        let person = DietPerson(weightKg: 200, heightCm: 196, age: 35, male: true)
        let result = DietTargets.resolve(adopted, person: person, burnKcal: 4_400)
        let weighIns = (0..<10).map { (day: String(format: "2026-12-%02d", $0 + 1), kg: 199 - Double($0) * 0.1) }
        let inside = DietAdjust.weekly(plan: adopted, result: result, weighIns: weighIns, loggedDays: 7,
                                       today: "2026-12-10")
        XCTAssertEqual(inside.hold, .burnModelChanged)
        let after = DietAdjust.weekly(plan: adopted, result: result, weighIns: weighIns, loggedDays: 7,
                                      today: "2026-12-13")
        XCTAssertNotEqual(after.hold, .burnModelChanged)
    }
}
