import XCTest
@testable import StrandDesign

/// Last Workouts colours each row by sport family (2026-10-02). Pins the families, the case-insensitive
/// match, and that no sport is ever given Effort's orange.
final class SportColorRoleTests: XCTestCase {
    func testFamiliesShareAHue() {
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Running"), .green)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Treadmill run"), .green)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Walking"), .mint)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Hiking"), .mint)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Cycling"), .yellow)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Indoor cycle"), .yellow)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Pool swim"), .cyan)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Strength Training"), .blue)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Weightlifting"), .blue)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "HIIT"), .pink)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Yoga"), .purple)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Tennis"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Basketball"), .indigo)
        XCTAssertEqual(AppleInspiredColors.role(forSport: "Something new"), .gray)
    }

    func testNoSportIsOrange() {
        for type in KnownWorkoutType.allCases {
            XCTAssertNotEqual(AppleInspiredColors.role(forSport: type.rawValue), .orange, type.rawValue)
        }
    }

    /// Explore gives each metric its category family's colours in order: neighbours differ, the id form
    /// resolves to the same role, and the plain category ids keep their old colour.
    func testExploreNeighboursDifferAndIdsResolve() {
        for category in ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind", "Other"] {
            for i in 0..<12 {
                XCTAssertNotEqual(AppleInspiredColors.exploreMetricRole(category: category, index: i),
                                  AppleInspiredColors.exploreMetricRole(category: category, index: i + 1))
                XCTAssertEqual(AppleInspiredColors.role(for: "explore.\(category.lowercased()).\(i)"),
                               AppleInspiredColors.exploreMetricRole(category: category, index: i))
            }
        }
        XCTAssertEqual(AppleInspiredColors.role(for: "explore.heart"), .red)
        XCTAssertEqual(AppleInspiredColors.exploreMetricRole(category: "Heart", index: 0), .red)
    }
}
