import XCTest
@testable import StrandImport

final class LabReportTextImportTests: XCTestCase {
    func testExtractsKnownMarkersWithoutMakingClinicalJudgements() {
        let result = LabReportTextImport.parse(text: """
        Ferritin: 42 µg/L (reference 15-150)
        HbA1c 34 mmol/mol
        Vitamin D 74 nmol/L
        """)

        XCTAssertFalse(result.textTooLarge)
        XCTAssertEqual(result.candidates.map(\.markerKey), ["ferritin", "hba1c", "vitamin_d"])
        XCTAssertEqual(result.candidates.first { $0.markerKey == "ferritin" }?.value, 42)
        XCTAssertEqual(result.candidates.first { $0.markerKey == "ferritin" }?.unit, "µg/L")
    }

    func testBloodPressurePairBecomesTwoReviewCandidates() {
        let result = LabReportTextImport.parse(text: "Blood pressure: 120/80 mmHg")
        XCTAssertEqual(result.candidates.map(\.markerKey), ["bp_diastolic", "bp_systolic"])
        XCTAssertEqual(result.candidates.first { $0.markerKey == "bp_systolic" }?.value, 120)
        XCTAssertEqual(result.candidates.first { $0.markerKey == "bp_diastolic" }?.value, 80)
    }

    func testUnknownTextIsNotInventedAsACustomMarker() {
        let result = LabReportTextImport.parse(text: "Mystery protein: 17 wobble-units")
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.skippedLines, 1)
    }

    func testOversizedTextIsRejectedBeforeScanning() {
        let result = LabReportTextImport.parse(text: String(repeating: "x", count: LabReportTextImport.maxCharacters + 1))
        XCTAssertTrue(result.textTooLarge)
        XCTAssertTrue(result.candidates.isEmpty)
    }
}
