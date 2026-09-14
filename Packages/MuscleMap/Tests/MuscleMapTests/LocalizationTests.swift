import XCTest
@testable import MuscleMap

final class LocalizationTests: XCTestCase {
    private let english = Locale(identifier: "en")

    func testAllMuscleDisplayNamesNotEmpty() {
        for muscle in Muscle.allCases {
            XCTAssertFalse(muscle.displayName.isEmpty, "\(muscle) has empty displayName")
        }
    }

    func testDisplayNameDoesNotReturnRawKey() {
        for muscle in Muscle.allCases {
            XCTAssertFalse(
                muscle.displayName.hasPrefix("muscle."),
                "\(muscle) displayName returned raw key: \(muscle.displayName)"
            )
        }
    }

    func testEnglishDisplayNamesMatchExpected() {
        XCTAssertEqual(Muscle.abs.displayName(locale: english), "Abs")
        XCTAssertEqual(Muscle.chest.displayName(locale: english), "Chest")
        XCTAssertEqual(Muscle.lowerBack.displayName(locale: english), "Lower Back")
        XCTAssertEqual(Muscle.upperBack.displayName(locale: english), "Upper Back")
        XCTAssertEqual(Muscle.quadriceps.displayName(locale: english), "Quadriceps")
        XCTAssertEqual(Muscle.rotatorCuff.displayName(locale: english), "Rotator Cuff")
        XCTAssertEqual(Muscle.hipFlexors.displayName(locale: english), "Hip Flexors")
        XCTAssertEqual(Muscle.upperChest.displayName(locale: english), "Upper Chest")
        XCTAssertEqual(Muscle.frontDeltoid.displayName(locale: english), "Front Deltoid")
    }

    func testMuscleSideDisplayName() {
        XCTAssertEqual(MuscleSide.left.displayName(locale: english), "Left")
        XCTAssertEqual(MuscleSide.right.displayName(locale: english), "Right")
        XCTAssertEqual(MuscleSide.both.displayName(locale: english), "Both")
    }

    func testBodySideDisplayName() {
        XCTAssertEqual(BodySide.front.displayName(locale: english), "Front")
        XCTAssertEqual(BodySide.back.displayName(locale: english), "Back")
    }

    func testBodyGenderDisplayName() {
        XCTAssertEqual(BodyGender.male.displayName(locale: english), "Male")
        XCTAssertEqual(BodyGender.female.displayName(locale: english), "Female")
    }
}
