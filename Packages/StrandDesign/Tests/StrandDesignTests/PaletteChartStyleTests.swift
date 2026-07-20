import XCTest
import SwiftUI
@testable import StrandDesign

/// Pins the new "Apple Health" `ChartStyle` (a third data-viz colour mode alongside Titanium/Classic,
/// selectable in Settings): it round-trips through storage, and every data-ramp accessor that branches
/// on `chartStyle` returns a valid, distinct colour for it — not a fallback to Titanium/Classic. `chartStyle`
/// is a mutable global (StrandPalette.chartStyle), so every test resets it in tearDown to avoid leaking
/// state into other test files that assume the `.titanium` default.
final class PaletteChartStyleTests: XCTestCase {

    override func tearDown() {
        StrandPalette.chartStyle = .titanium
        super.tearDown()
    }

    func testHealthIsAChartStyleCase() {
        XCTAssertTrue(ChartStyle.allCases.contains(.health))
    }

    func testHealthRoundTripsThroughStorage() {
        XCTAssertEqual(ChartStyle.resolve("health"), .health)
        XCTAssertEqual(ChartStyle.resolve(ChartStyle.health.rawValue), .health)
    }

    func testHealthHasANonEmptyLabel() {
        XCTAssertFalse(ChartStyle.health.label.isEmpty)
    }

    func testRecoveryAndStrainStopsAreValidUnderHealth() {
        StrandPalette.chartStyle = .health
        XCTAssertEqual(StrandPalette.recoveryStops.count, 5)
        XCTAssertEqual(StrandPalette.recoveryStops.first?.location, 0.0)
        XCTAssertEqual(StrandPalette.recoveryStops.last?.location, 1.0)
        XCTAssertEqual(StrandPalette.strainStops.count, 4)
    }

    func testStatusColorsAreDistinctUnderHealth() {
        StrandPalette.chartStyle = .health
        let positive = StrandPalette.statusPositive.rgbaComponents
        let warning = StrandPalette.statusWarning.rgbaComponents
        let critical = StrandPalette.statusCritical.rgbaComponents
        // Apple's systemGreen / systemYellow / systemRed must not collapse onto each other.
        XCTAssertNotEqual(positive.g, critical.g, accuracy: 0.001)
        XCTAssertNotEqual(warning.r, positive.r, accuracy: 0.001)
    }

    func testDomainWorldColorsAreDistinctUnderHealth() {
        StrandPalette.chartStyle = .health
        let charge = StrandPalette.chargeColor.rgbaComponents
        let effort = StrandPalette.effortColor.rgbaComponents
        let rest = StrandPalette.restColor.rgbaComponents
        let stress = StrandPalette.stressColor.rgbaComponents
        // Charge=systemGreen, Effort=systemOrange, Rest=systemIndigo, Stress=systemYellow — four
        // different hue families, so no two should resolve to (near-)identical RGB.
        func closeEnoughToCollide(_ a: (r: Double, g: Double, b: Double, a: Double),
                                   _ b: (r: Double, g: Double, b: Double, a: Double)) -> Bool {
            abs(a.r - b.r) < 0.02 && abs(a.g - b.g) < 0.02 && abs(a.b - b.b) < 0.02
        }
        XCTAssertFalse(closeEnoughToCollide(charge, effort))
        XCTAssertFalse(closeEnoughToCollide(charge, rest))
        XCTAssertFalse(closeEnoughToCollide(charge, stress))
        XCTAssertFalse(closeEnoughToCollide(effort, rest))
        XCTAssertFalse(closeEnoughToCollide(effort, stress))
        XCTAssertFalse(closeEnoughToCollide(rest, stress))
    }

    func testSleepStageColorsAreDistinctUnderHealth() {
        StrandPalette.chartStyle = .health
        XCTAssertEqual(StrandPalette.sleepStageColor(.rem).rgbaComponents.r,
                       StrandPalette.sleepREM.rgbaComponents.r, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.sleepStageColor(.awake).rgbaComponents.r,
                       StrandPalette.sleepAwake.rgbaComponents.r, accuracy: 0.001)
    }

    func testHRZoneColorUnderHealth() {
        StrandPalette.chartStyle = .health
        XCTAssertEqual(StrandPalette.hrZoneColor(1).rgbaComponents.b,
                       StrandPalette.zone1.rgbaComponents.b, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.hrZoneColor(5).rgbaComponents.r,
                       StrandPalette.zone5.rgbaComponents.r, accuracy: 0.001)
    }

    /// Switching between all three styles must never crash or produce an empty gradient — the
    /// smoke test the whole 3-way switch conversion exists to guard.
    func testAllThreeChartStylesProduceNonEmptyGradients() {
        for style in ChartStyle.allCases {
            StrandPalette.chartStyle = style
            XCTAssertFalse(StrandPalette.recoveryStops.isEmpty)
            XCTAssertFalse(StrandPalette.strainStops.isEmpty)
            XCTAssertNotNil(StrandPalette.stressGradient)
        }
    }
}
