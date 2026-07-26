import XCTest
import StrandDesign

final class AppleInspiredColorsTests: XCTestCase {

    func testSemanticRolesCoverThePrimaryAppleInterfaceDomains() {
        XCTAssertEqual(AppleInspiredColors.role(for: "sleep"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "alarms"), .orange)
        XCTAssertEqual(AppleInspiredColors.role(for: "workouts"), .green)
        XCTAssertEqual(AppleInspiredColors.role(for: "health"), .pink)
        XCTAssertEqual(AppleInspiredColors.role(for: "dataSources"), .gray)
        XCTAssertEqual(AppleInspiredColors.role(for: "coach"), .purple)
    }

    func testExistingNavigationAndSettingsMappingsRemainStable() {
        XCTAssertEqual(AppleInspiredColors.role(for: "automations"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "live"), .red)
        XCTAssertEqual(AppleInspiredColors.role(for: "circle.lefthalf.filled"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(for: "bed.double.fill"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "coach.goal.sleep"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(for: "coach.settings.privacy"), .teal)
    }

    func testDisabledPreferenceFallsBackToTheExistingBlueAccent() {
        XCTAssertEqual(AppleInspiredColors.color(for: "sleep", enabled: false), StrandPalette.accent)
        XCTAssertEqual(AppleInspiredColorsPrefs.enabledKey, "noop.moreRowAppleHealthColors")
        XCTAssertTrue(AppleInspiredColorsPrefs.defaultEnabled)
    }

    func testUnknownRoleUsesAppleSystemBlue() {
        XCTAssertEqual(AppleInspiredColors.role(for: "unrecognized.primary.control"), .blue)
    }
}
