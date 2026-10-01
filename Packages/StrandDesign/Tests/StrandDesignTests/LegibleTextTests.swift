import XCTest
@testable import StrandDesign

final class LegibleTextTests: XCTestCase {
    private func contrast(_ c: (r: Double, g: Double, b: Double)) -> Double {
        LegibleText.contrast(c, LegibleText.lightSurface)
    }

    func testBrightAccentsReachTheMinimumOnWhite() {
        // Yellow, orange and mint accents as used for rings and fills.
        let accents: [(Double, Double, Double)] = [(1.0, 0.8, 0.0), (1.0, 0.58, 0.0), (0.2, 0.78, 0.35), (0.19, 0.69, 0.78)]
        for a in accents {
            let d = LegibleText.darkened(r: a.0, g: a.1, b: a.2)
            XCTAssertGreaterThanOrEqual(contrast(d), LegibleText.minimumContrast, "\(a)")
        }
    }

    func testAnAlreadyReadableColourIsLeftAlone() {
        let dark = LegibleText.darkened(r: 0.1, g: 0.1, b: 0.4)
        XCTAssertEqual(dark.r, 0.1, accuracy: 1e-9)
        XCTAssertEqual(dark.g, 0.1, accuracy: 1e-9)
        XCTAssertEqual(dark.b, 0.4, accuracy: 1e-9)
    }

    func testDarkeningKeepsTheHueOrder() {
        let d = LegibleText.darkened(r: 1.0, g: 0.8, b: 0.0)
        XCTAssertGreaterThan(d.r, d.g)
        XCTAssertGreaterThan(d.g, d.b)
    }

    func testWhiteIsDarkenedAllTheWayToReadable() {
        XCTAssertGreaterThanOrEqual(contrast(LegibleText.darkened(r: 1, g: 1, b: 1)), LegibleText.minimumContrast)
    }
}
