import XCTest
import SwiftUI
@testable import StrandDesign

final class AppleHealthAppearanceTests: XCTestCase {
    private var originalAccent: AccentColor!
    private var originalChartStyle: ChartStyle!

    override func setUp() {
        super.setUp()
        originalAccent = StrandPalette.accentChoice
        originalChartStyle = StrandPalette.chartStyle
    }

    override func tearDown() {
        StrandPalette.accentChoice = originalAccent
        StrandPalette.chartStyle = originalChartStyle
        super.tearDown()
    }

    func testSystemBlueRoundTripsThroughStorage() {
        XCTAssertTrue(AccentColor.allCases.contains(.systemBlue))
        XCTAssertEqual(AccentColor.resolve("systemBlue"), .systemBlue)
        XCTAssertEqual(AccentColor.resolve(AccentColor.systemBlue.rawValue), .systemBlue)
        XCTAssertEqual(AccentColor.resolve("unknown"), .systemBlue)
        XCTAssertFalse(AccentColor.systemBlue.label.isEmpty)
    }

    func testGlobalDefaultsFavorAppleHealth() {
        XCTAssertEqual(StrandPalette.accentChoice, .systemBlue)
        XCTAssertEqual(StrandPalette.chartStyle, .health)
    }

    func testSystemBlueUsesAppleSystemBlueValues() {
        let blue = AccentColor.systemBlue.accent.rgbaComponents
        let light = (r: 0x00 / 255.0, g: 0x7A / 255.0, b: 0xFF / 255.0)
        let dark = (r: 0x0A / 255.0, g: 0x84 / 255.0, b: 0xFF / 255.0)
        let matchesLight = abs(blue.r - light.r) < 0.01 && abs(blue.g - light.g) < 0.01 && abs(blue.b - light.b) < 0.01
        let matchesDark = abs(blue.r - dark.r) < 0.01 && abs(blue.g - dark.g) < 0.01 && abs(blue.b - dark.b) < 0.01
        XCTAssertTrue(matchesLight || matchesDark)
    }

    func testAppleHealthPresetCoordinatesSystemBlueAndHealthData() throws {
        let recipe = try XCTUnwrap(ThemePreset.health.recipe)
        XCTAssertEqual(recipe.accent, .systemBlue)
        XCTAssertEqual(recipe.chart, .health)
        XCTAssertFalse(recipe.backdrop)
        XCTAssertEqual(recipe.cardOpacity, 100)
        XCTAssertEqual(
            ThemePreset.matching(
                accent: recipe.accent,
                chart: recipe.chart,
                backdrop: recipe.backdrop,
                cardOpacity: recipe.cardOpacity),
            .health)
    }

    func testAppleHealthGlobalPaletteUsesSystemBlueAndDistinctSemanticDataColors() {
        StrandPalette.accentChoice = .systemBlue
        StrandPalette.chartStyle = .health

        let accent = StrandPalette.accent.rgbaComponents
        let expected = AccentColor.systemBlue.accent.rgbaComponents
        XCTAssertEqual(accent.r, expected.r, accuracy: 0.001)
        XCTAssertEqual(accent.g, expected.g, accuracy: 0.001)
        XCTAssertEqual(accent.b, expected.b, accuracy: 0.001)

        let positive = StrandPalette.statusPositive.rgbaComponents
        let warning = StrandPalette.statusWarning.rgbaComponents
        let critical = StrandPalette.statusCritical.rgbaComponents
        XCTAssertNotEqual(positive.g, critical.g, accuracy: 0.001)
        XCTAssertNotEqual(warning.r, positive.r, accuracy: 0.001)
    }
}
