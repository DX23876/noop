import XCTest
@testable import Strand

@MainActor
final class TrainingWeightUnitTests: XCTestCase {
    func testExistingUsersDefaultToKilograms() {
        XCTAssertEqual(TrainingWeightUnit(rawValue: "") ?? .kilograms, .kilograms)
        XCTAssertEqual(TrainingWeightUnit.kilograms.symbol, "kg")
    }

    func testPoundsRoundTripThroughCanonicalKilograms() {
        let stored = TrainingPreferences.kilograms(fromDisplay: 225, unit: .pounds)
        XCTAssertEqual(stored, 225 / UnitFormatter.poundsPerKilogram, accuracy: 0.000_001)
        XCTAssertEqual(TrainingPreferences.displayWeight(stored, unit: .pounds), 225,
                       accuracy: 0.000_001)
    }

    func testNativeFivePoundIncrementIsStoredAsKilograms() {
        XCTAssertEqual(TrainingPreferences.defaultImperialWeightIncrementKg,
                       5 / UnitFormatter.poundsPerKilogram, accuracy: 0.000_001)
        XCTAssertEqual(TrainingPreferences.formattedWeight(
            TrainingPreferences.defaultImperialWeightIncrementKg, unit: .pounds), "5 lb")
    }

    func testConvertedPoundSummariesDoNotShowNoisyHundredths() {
        XCTAssertEqual(TrainingPreferences.formattedWeight(127.5, unit: .pounds), "281.1 lb")
        XCTAssertEqual(TrainingPreferences.formattedWeight(12.25, unit: .kilograms), "12.25 kg")
    }
}
