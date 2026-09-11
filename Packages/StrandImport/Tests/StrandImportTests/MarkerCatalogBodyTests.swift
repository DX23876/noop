import XCTest
@testable import StrandImport

/// Pins the circumference sites the Body page captures.
///
/// These keys are stored on every reading, so renaming one orphans a wearer's history. That is what
/// this suite is really guarding.
final class MarkerCatalogBodyTests: XCTestCase {

    /// Every circumference site the page offers has a definition behind it.
    func testEveryCircumferenceSiteHasADefinition() throws {
        for key in MarkerCatalog.circumferenceKeys {
            let definition = try XCTUnwrap(MarkerCatalog.definition(for: key),
                                           "no definition for \(key)")
            XCTAssertEqual(definition.category, .bodyMeasurement)
            XCTAssertEqual(definition.canonicalUnit, "cm")
        }
    }

    /// The keys are exactly the sites the spec names, in head-to-toe order — a stable order matters
    /// because the capture sheet and the page both read it.
    func testTheSitesAreTheOnesTheSpecNamesInOrder() {
        XCTAssertEqual(MarkerCatalog.circumferenceKeys, [
            "neck", "shoulders", "chest", "waist", "abdomen", "hips",
            "biceps_l", "biceps_r", "forearm_l", "forearm_r",
            "thigh_l", "thigh_r", "calf_l", "calf_r",
        ])
    }

    /// The pre-existing body keys are untouched — weight, body fat, waist and height already carried
    /// history before this feature existed.
    func testThePreExistingBodyKeysStillResolve() throws {
        for key in ["weight", "body_fat", "waist", "height"] {
            let definition = try XCTUnwrap(MarkerCatalog.definition(for: key))
            XCTAssertEqual(definition.category, .bodyMeasurement)
        }
        XCTAssertEqual(MarkerCatalog.definition(for: "body_fat")?.canonicalUnit, "%")
        XCTAssertEqual(MarkerCatalog.definition(for: "weight")?.canonicalUnit, "kg")
    }

    /// Body measurements ship no reference range — the Lab Book asserts no normal ranges anywhere,
    /// and a body-fat "normal range" would be a medical claim.
    func testBodyMeasurementsShipNoReferenceRange() {
        for key in MarkerCatalog.circumferenceKeys + ["weight", "body_fat", "height"] {
            XCTAssertNil(MarkerCatalog.definition(for: key)?.referenceTextHint, key)
            XCTAssertNil(MarkerCatalog.definition(for: key)?.higherIsBetter, key)
        }
    }
}
