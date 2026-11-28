import XCTest
import StrandCore
@testable import NoopCore

/// The coach judges a product's processing class itself (owner, 2026-11-28): Open Food Facts derives NOVA by rule
/// from single ingredient markers and called a protein bread and seasoned chicken strips ultra-processed.
final class CoachFoodClassifyTests: XCTestCase {
    func testTheAnswersProcessingClassIsKept() throws {
        let reply = #"{"groups": {"nuts": 0.3}, "whole_grain": 0.5, "free_sugar": 0.2, "processing": 3}"#
        let classification = try XCTUnwrap(CoachFoodClassify.parse(reply))
        XCTAssertEqual(classification.processing, 3)
        XCTAssertEqual(classification.groupShares[.nuts], 0.3)
    }

    func testAClassOutsideNovaIsLeftOutNotTheWholeAnswer() throws {
        let reply = #"{"groups": {}, "whole_grain": 1, "processing": 7}"#
        let classification = try XCTUnwrap(CoachFoodClassify.parse(reply))
        XCTAssertNil(classification.processing)
        XCTAssertEqual(classification.wholeGrainShare, 1)
    }

    func testTheJudgedClassStandsAboveTheLabels() {
        let judged = FoodClassification(processing: 3).facts(group: "bread", nova: 4)
        XCTAssertEqual(judged.nova, 3)
        let unjudged = FoodClassification(wholeGrainShare: 0.2).facts(group: "bread", nova: 4)
        XCTAssertEqual(unjudged.nova, 4, "without a judgement the label's class stands")
    }

    func testAStoredClassificationWithoutAProcessingClassStillReads() throws {
        let stored = #"{"shares":{},"wholeGrainShare":1,"freeSugarShare":0,"author":"coach","version":1}"#
        let classification = try XCTUnwrap(FoodClassification.decode(stored))
        XCTAssertNil(classification.processing)
        XCTAssertFalse(FoodClassification(processing: 5).isSound)
    }

    func testThePromptTellsTheModelTheLabelsClassIsARule() {
        let item = FoodItem(id: "own:x", source: .own, name: "EIWEISS BROT", nova: 4, per100g: NutrientAmounts())
        XCTAssertTrue(CoachFoodClassify.prompt(item).contains("from the label database, by rule: 4"))
        XCTAssertTrue(CoachFoodClassify.system.contains("\"processing\""))
    }

    func testAFigureTheModelLeftOutStaysOpen() throws {
        let classification = try XCTUnwrap(CoachFoodClassify.parse(#"{"groups": {}, "processing": 3}"#))
        XCTAssertNil(classification.wholeGrainShare)
        XCTAssertNil(classification.freeSugarShare)
        XCTAssertEqual(classification.processing, 3)
    }

    func testSharesALittleOverTheWholeAreScaledNotRefused() throws {
        let reply = #"{"groups": {"nuts": 0.6, "legumes": 0.45}, "whole_grain": 0.3, "processing": 3}"#
        let classification = try XCTUnwrap(CoachFoodClassify.parse(reply))
        let shares = classification.groupShares
        XCTAssertEqual((shares[.nuts] ?? 0) + (shares[.legumes] ?? 0), 1, accuracy: 0.0001)
        XCTAssertEqual(classification.processing, 3)
        XCTAssertNil(CoachFoodClassify.parse(#"{"groups": {"nuts": 1.4}}"#), "one share beyond the whole is refused")
    }

    func testTheGateHoldsARunningAndAFailedProductBack() {
        let gate = FoodClassifyGate()
        XCTAssertTrue(gate.begin("own:a"))
        XCTAssertFalse(gate.begin("own:a"), "never asked twice at once")
        gate.end("own:a", succeeded: false)
        XCTAssertFalse(gate.isAvailable("own:a"), "a failure is not retried in the same run")
        XCTAssertTrue(gate.begin("own:b"))
        gate.end("own:b", succeeded: true)
        XCTAssertTrue(gate.isAvailable("own:b"))
    }

    func testClassifyingLoggedKeepsTheFoundIngredients() {
        var found = FoodItem(id: "off:1", source: .online, name: "EIWEISS BROT", per100g: NutrientAmounts())
        found.ingredients = "Weizeneiweiß, Sojaschrot"
        let stored = FoodItem(id: "own:1", source: .own, name: "EIWEISS BROT", per100g: NutrientAmounts())
        XCTAssertNil(stored.ingredients)
        XCTAssertTrue(CoachFoodClassify.prompt({ var s = stored; s.ingredients = s.ingredients ?? found.ingredients; return s }())
            .contains("Weizeneiweiß"))
    }
}
