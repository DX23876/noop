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
}
