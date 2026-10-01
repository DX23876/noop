import XCTest
import StrandDesign

final class AppleInspiredColorsTests: XCTestCase {

    func testFeatureFamiliesUseStableSemanticRoles() {
        XCTAssertEqual(AppleInspiredColors.role(for: "coach"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "coachSettings"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "coach.preset.supportive"), .red)
        XCTAssertEqual(AppleInspiredColors.role(for: "journal"), .orange)
        XCTAssertEqual(AppleInspiredColors.role(for: "insights"), .orange)
        XCTAssertEqual(AppleInspiredColors.role(for: "sleep"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "alarms"), .orange)
        XCTAssertEqual(AppleInspiredColors.role(for: "workouts"), .green)
        XCTAssertEqual(AppleInspiredColors.role(for: "health"), .red)
        XCTAssertEqual(AppleInspiredColors.role(for: "dataSources"), .gray)
    }

    func testExploreCategoriesUseDistinctAppleInspiredRoles() {
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.timeline"), .red)
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.heart"), .red)
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.charge"), .green)
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.rest"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.effort"), .orange)
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.health"), .teal)
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.nutrition"), .orange)
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.mind"), .purple)
    }

    func testLegacyNavigationAndSettingsMappingsRemainStable() {
        XCTAssertEqual(AppleInspiredColors.role(for: "automations"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "live"), .red)
        XCTAssertEqual(AppleInspiredColors.role(for: "circle.lefthalf.filled"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "flask.fill"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "bed.double.fill"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "coach.goal.sleep"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "coach.settings.privacy"), .teal)
    }

    func testDisabledPreferenceFallsBackToTheExistingAccent() {
        XCTAssertEqual(AppleInspiredColors.color(for: "sleep", enabled: false), StrandPalette.accent)
        XCTAssertEqual(AppleInspiredColorsPrefs.enabledKey, "noop.moreRowAppleHealthColors")
        XCTAssertTrue(AppleInspiredColorsPrefs.defaultEnabled)
    }

    func testUnknownRoleUsesSystemBlue() {
        XCTAssertEqual(AppleInspiredColors.role(for: "unrecognized.primary.control"), .blue)
    }
}
