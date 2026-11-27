import XCTest
@testable import StrandCore

/// Package sizes as Open Food Facts states them, and the amounts the amount sheet offers from them.
final class FoodPortionsTests: XCTestCase {
    func testPackagesAreReadFromTheLabelText() {
        XCTAssertEqual(FoodPackage.parse(text: "6 x 330 ml"), FoodPackage(amount: 330, count: 6, liquid: true))
        XCTAssertEqual(FoodPackage.parse(text: "6×0,33 l"), FoodPackage(amount: 330, count: 6, liquid: true))
        XCTAssertEqual(FoodPackage.parse(text: "500g"), FoodPackage(amount: 500, liquid: false))
        XCTAssertEqual(FoodPackage.parse(text: "1,5 l"), FoodPackage(amount: 1500, liquid: true))
        XCTAssertEqual(FoodPackage.parse(text: "75 cl"), FoodPackage(amount: 750, liquid: true))
        XCTAssertEqual(FoodPackage.parse(text: "1 kg"), FoodPackage(amount: 1000, liquid: false))
        XCTAssertNil(FoodPackage.parse(text: "2 Stück"), "a count without a size is no package")
        XCTAssertNil(FoodPackage.parse(text: "12 oz"), "an unknown unit is left out, not guessed")
    }

    func testTheProductQuantityStandsInWhenTheTextSaysNothing() {
        XCTAssertEqual(FoodPackage.parse(quantity: "1 Flasche", productQuantity: 500, unit: "ml"),
                       FoodPackage(amount: 500, liquid: true))
        XCTAssertNil(FoodPackage.parse(quantity: nil, productQuantity: 500, unit: nil))
        XCTAssertNil(FoodPackage.parse(quantity: "0 g", productQuantity: nil, unit: nil), "a size of nothing is no size")
    }

    private func item(serving: Double? = nil, liquid: Bool = false, amount: Double? = nil, count: Int? = nil) -> FoodItem {
        FoodItem(id: "off:1", source: .online, name: "x", servingG: serving, per100g: NutrientAmounts(),
                 liquid: liquid ? true : nil, packageAmount: amount, packageCount: count)
    }

    func testAMultipackOffersOnePieceAndTheWholePack() {
        let options = FoodPortions.options(for: item(liquid: true, amount: 330, count: 6), lastAmount: nil)
        XCTAssertEqual(options.map(\.kind), [.piece(count: 6), .wholePack(count: 6), .amount, .amount, .amount])
        XCTAssertEqual(options.map(\.amount), [330, 1980, 100, 250, 500], "round amounts in millilitres for a drink")
    }

    func testASinglePackOffersHalfAndWhole() {
        let options = FoodPortions.options(for: item(serving: 40, amount: 400), lastAmount: 60)
        XCTAssertEqual(options.map(\.kind), [.serving(label: nil), .lastTime, .halfPack, .wholePack(count: 1),
                                             .amount, .amount, .amount])
        XCTAssertEqual(options.map(\.amount), [40, 60, 200, 400, 50, 100, 250])
    }

    func testNoPackageNoPackageOptionAndNoDoubles() {
        let options = FoodPortions.options(for: item(serving: 100), lastAmount: 100)
        XCTAssertEqual(options.map(\.amount), [100, 50, 250], "an amount offered twice is offered once")
    }

    func testOnlineDrinksAreMeasuredInMillilitres() {
        let json: [String: Any] = ["code": "5449000000996", "product_name": "Cola", "quantity": "330 ml",
                                   "product_quantity": 330, "product_quantity_unit": "ml",
                                   "nutriments": ["energy-kcal_100g": 42, "proteins_100g": 0,
                                                  "carbohydrates_100g": 10.6, "fat_100g": 0]]
        let cola = FoodOnline.product(json, language: "de")
        XCTAssertEqual(cola?.liquid, true)
        XCTAssertEqual(cola?.packageAmount, 330)
        XCTAssertEqual(cola?.packageCount, 1)
    }
}
