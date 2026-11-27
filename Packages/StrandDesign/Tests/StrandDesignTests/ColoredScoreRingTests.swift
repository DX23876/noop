import SwiftUI
import XCTest
@testable import StrandDesign

/// The coloured score rings (Settings, Style, Rings: Colored): Charge is a traffic light by its band whatever
/// chart colours are chosen, Effort is blue, Rest light blue, and a missing score is grey.
final class ColoredScoreRingTests: XCTestCase {

    override func tearDown() {
        StrandPalette.chartStyle = .health
        super.tearDown()
    }

    private func assertSame(_ a: Color, _ b: Color, _ message: String, line: UInt = #line) {
        let x = a.rgbaComponents, y = b.rgbaComponents
        XCTAssertEqual(x.r, y.r, accuracy: 0.001, message, line: line)
        XCTAssertEqual(x.g, y.g, accuracy: 0.001, message, line: line)
        XCTAssertEqual(x.b, y.b, accuracy: 0.001, message, line: line)
    }

    /// Each band takes its classic readiness swatch, red at the bottom to green at the top, under every
    /// chart style: the coloured rings do not follow the chart colours.
    func testChargeIsATrafficLightByBandUnderEveryChartStyle() {
        let expected: [(Double, Color)] = [(10, StrandPalette.cRecovery000), (30, StrandPalette.cRecovery030),
                                           (60, StrandPalette.cRecovery055), (75, StrandPalette.cRecovery078),
                                           (95, StrandPalette.cRecovery100)]
        for style in ChartStyle.allCases {
            StrandPalette.chartStyle = style
            for (score, swatch) in expected {
                assertSame(StrandPalette.coloredRingCharge(score), swatch, "Charge \(score) under \(style)")
                assertSame(StrandPalette.coloredRingTint(metric: .charge, score: score), swatch,
                           "tint for Charge \(score) under \(style)")
            }
        }
    }

    func testEffortIsBlueRestLightBlueAndAMissingScoreGrey() {
        assertSame(StrandPalette.coloredRingTint(metric: .effort, score: 40), StrandPalette.coloredRingEffort, "Effort")
        assertSame(StrandPalette.coloredRingTint(metric: .rest, score: 80), StrandPalette.coloredRingRest, "Rest")
        for metric in OrganicScoreMetric.allCases {
            assertSame(StrandPalette.coloredRingTint(metric: metric, score: nil), StrandPalette.organicMissing,
                       "missing \(metric)")
        }
    }

    /// Effort and Rest must not read as one colour, or the coloured rings would lose what they are for.
    func testEffortAndRestAreDifferentColours() {
        let e = StrandPalette.coloredRingEffort.rgbaComponents, r = StrandPalette.coloredRingRest.rgbaComponents
        XCTAssertGreaterThan(abs(e.r - r.r) + abs(e.g - r.g) + abs(e.b - r.b), 0.2)
    }
}
