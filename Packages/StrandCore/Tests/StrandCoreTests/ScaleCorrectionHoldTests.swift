import XCTest
@testable import StrandCore

/// What holds the scale's correction still (owner decision 2026-11-27, Q23).
final class ScaleCorrectionHoldTests: XCTestCase {
    private func plan(start: String, form: String? = nil, model: String? = nil) -> DietPlan {
        var p = DietPlan(goal: .lose, startDay: start, startWeightKg: 200)
        p.formChangedDay = form
        p.burnModelChangedDay = model
        return p
    }

    func testAPlanStartOrAFormChangeHoldsThreeWeeks() {
        XCTAssertTrue(ScaleCorrectionUpdate.holding(today: "2026-12-10", plan: plan(start: "2026-12-01"),
                                                    strengthDays: [], creatineStarts: []))
        XCTAssertFalse(ScaleCorrectionUpdate.holding(today: "2026-12-30", plan: plan(start: "2026-12-01"),
                                                     strengthDays: [], creatineStarts: []))
        XCTAssertTrue(ScaleCorrectionUpdate.holding(today: "2027-01-10",
                                                    plan: plan(start: "2026-10-01", form: "2027-01-01"),
                                                    strengthDays: [], creatineStarts: []))
    }

    func testCreatineHoldsFourWeeks() {
        XCTAssertTrue(ScaleCorrectionUpdate.holding(today: "2026-12-25", plan: nil, strengthDays: [],
                                                    creatineStarts: ["2026-12-01"]))
        XCTAssertFalse(ScaleCorrectionUpdate.holding(today: "2027-01-05", plan: nil, strengthDays: [],
                                                     creatineStarts: ["2026-12-01"]))
    }

    /// Strength training back after four weeks without holds; ordinary weekly training does not.
    func testStrengthAfterABreakHoldsButRegularTrainingDoesNot() {
        XCTAssertTrue(ScaleCorrectionUpdate.holding(today: "2026-12-10", plan: nil,
                                                    strengthDays: ["2026-10-20", "2026-12-05"], creatineStarts: []))
        XCTAssertFalse(ScaleCorrectionUpdate.holding(today: "2026-12-10", plan: nil,
                                                     strengthDays: ["2026-11-28", "2026-12-01", "2026-12-05"],
                                                     creatineStarts: []))
    }

    /// The early look's words come from the core, so both platforms say the same (review 2026-11-27).
    func testTheEarlyLookSaysAgreeUnderThreePercent() {
        XCTAssertEqual(ScaleCorrectionUpdate.earlyWords(ratio: 1.024).direction, "same")
        XCTAssertEqual(ScaleCorrectionUpdate.earlyWords(ratio: 0.976).direction, "same")
        let more = ScaleCorrectionUpdate.earlyWords(ratio: 1.124)
        XCTAssertEqual(more.direction, "more"); XCTAssertEqual(more.percent, 12)
        let less = ScaleCorrectionUpdate.earlyWords(ratio: 0.93)
        XCTAssertEqual(less.direction, "less"); XCTAssertEqual(less.percent, 7)
    }
}
