import XCTest
import SwiftUI
@testable import StrandDesign
@testable import Strand

final class NightDetailDebtFormattingTests: XCTestCase {
    func testTenMinuteDebtBoundary() {
        XCTAssertEqual(nightDetailDebtCaption(9.9), String(localized: "On target"))
        assertSameResolvedColor(nightDetailDebtColor(9.9), StrandPalette.statusPositive)

        XCTAssertEqual(nightDetailDebtCaption(10.0), String(localized: "Below need"))
        assertSameResolvedColor(nightDetailDebtColor(10.0), StrandPalette.statusWarning)
    }

    func testImportedDebtAboveBoundaryRemainsDebt() {
        XCTAssertEqual(nightDetailDebtCaption(12.5), String(localized: "Below need"))
        assertSameResolvedColor(nightDetailDebtColor(12.5), StrandPalette.statusWarning)
    }

    private func assertSameResolvedColor(
        _ actual: SwiftUI.Color,
        _ expected: SwiftUI.Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualRGBA = actual.rgbaComponents
        let expectedRGBA = expected.rgbaComponents
        XCTAssertEqual(actualRGBA.r, expectedRGBA.r, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGBA.g, expectedRGBA.g, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGBA.b, expectedRGBA.b, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGBA.a, expectedRGBA.a, accuracy: 0.001, file: file, line: line)
    }
}
