import XCTest
@testable import WhoopProtocol

/// Registry model-label → `DeviceFamily` resolution (#171). Mirrors the Android `RegistryModelFamilyTest`.
///
/// The device registry holds several historical spellings for the same hardware — the Add-Device
/// wizard's bare "4.0" / "5.0 MG", the full picker labels ("WHOOP 4.0" / "WHOOP 5.0 / MG"), and the
/// legacy seeded "my-whoop" row's bare "WHOOP". Call sites that compared ONE spelling silently missed
/// the others (issue #171: wizard-paired 4.0 straps decoded on the 5/MG /100 scale, ~8 °C skin temps
/// in the Deep Timeline). These tests pin the full label contract so a new spelling — or a regression
/// back to a single-spelling comparison — fails loudly.
final class RegistryModelFamilyTests: XCTestCase {

    // MARK: - WHOOP 4.0 — every stored spelling must positively identify (the #171 fix)

    func testWizardBare40LabelResolvesToWhoop4() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("4.0"), .whoop4)
    }

    func testFullPicker40LabelResolvesToWhoop4() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP 4.0"), .whoop4)
    }

    // MARK: - WHOOP 5/MG — both spellings keep the /100 path

    func testWizard5MgLabelResolvesToWhoop5() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("5.0 MG"), .whoop5)
        // "WHOOP 5.0 MG" is a spelling no writer produces today (the picker writes
        // "WHOOP 5.0 / MG"); it lands on the safe .whoop5 default, which happens to be correct.
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP 5.0 MG"), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP 5.0 / MG"), .whoop5)
    }

    // MARK: - Legacy + unknowns — the prior .whoop5 fallback, unchanged

    /// The seeded "my-whoop" row predates the wizard and was written identically for 4.0 and 5/MG
    /// installs, so "WHOOP" carries no family information; it keeps the prior fallback.
    func testLegacySeededWhoopLabelKeepsWhoop5Fallback() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP"), .whoop5)
    }

    func testNilEmptyAndGarbageFallBackToWhoop5() {
        XCTAssertEqual(DeviceFamily.forRegistryModel(nil), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel(""), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel("Oura Ring Gen3"), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel("garmin-hrm"), .whoop5)
    }
}
