import XCTest
import StrandDesign

final class AppleInspiredColorsTests: XCTestCase {

    func testFeatureFamiliesUseStableSemanticRoles() {
        XCTAssertEqual(AppleInspiredColors.role(for: "coach"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "coachSettings"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "coach.preset.supportive"), .pink)
        XCTAssertEqual(AppleInspiredColors.role(for: "journal"), .brown)
        XCTAssertEqual(AppleInspiredColors.role(for: "sleep"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "alarms"), .orange)
        XCTAssertEqual(AppleInspiredColors.role(for: "workouts"), .green)
        XCTAssertEqual(AppleInspiredColors.role(for: "health"), .pink)
        XCTAssertEqual(AppleInspiredColors.role(for: "dataSources"), .gray)
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
