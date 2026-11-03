import XCTest
@testable import StrandImport

final class LabReferenceRangesTests: XCTestCase {
    func testGeneralRangeRatesAReadingInItsCanonicalUnit() throws {
        let ldl = try XCTUnwrap(LabReferenceRanges.range(markerKey: "ldl", unit: "mmol/L", referenceText: nil))
        XCTAssertEqual(ldl.origin, .general)
        XCTAssertEqual(ldl.status(of: 3.6), .high)
        XCTAssertEqual(ldl.status(of: 2.4), .inRange)
        let vitaminD = try XCTUnwrap(LabReferenceRanges.range(markerKey: "vitamin_d", unit: "nmol/L", referenceText: nil))
        XCTAssertEqual(vitaminD.status(of: 30), .low)
    }

    func testAReadingInAnotherUnitGetsNoRating() {
        XCTAssertNil(LabReferenceRanges.range(markerKey: "ldl", unit: "mg/dL", referenceText: nil))
        XCTAssertNil(LabReferenceRanges.range(markerKey: "weight", unit: "kg", referenceText: nil))
    }

    func testTheWearersOwnReportWinsOverTheGeneralRange() throws {
        let own = try XCTUnwrap(LabReferenceRanges.range(markerKey: "ldl", unit: "mmol/L", referenceText: "1,0 - 4,0"))
        XCTAssertEqual(own.origin, .ownReport)
        XCTAssertEqual(own.status(of: 3.6), .inRange)
        // Even when the unit would have no general range.
        XCTAssertEqual(LabReferenceRanges.range(markerKey: "ldl", unit: "mg/dL", referenceText: "< 115")?.upper, 115)
    }

    func testParsingTheCommonReportForms() {
        XCTAssertEqual(LabReferenceRanges.parse("3.5-5.1")?.lower, 3.5)
        XCTAssertEqual(LabReferenceRanges.parse("3,5 – 5,1")?.upper, 5.1)
        XCTAssertEqual(LabReferenceRanges.parse("< 3.0")?.upper, 3.0)
        XCTAssertEqual(LabReferenceRanges.parse("> 1.0")?.lower, 1.0)
        XCTAssertNil(LabReferenceRanges.parse("see report"))
        XCTAssertNil(LabReferenceRanges.parse(""))
        XCTAssertNil(LabReferenceRanges.parse(nil))
        XCTAssertNil(LabReferenceRanges.parse("5-3"))
    }
}
