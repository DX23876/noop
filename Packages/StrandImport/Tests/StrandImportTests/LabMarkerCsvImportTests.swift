import XCTest
@testable import StrandImport

final class LabMarkerCsvImportTests: XCTestCase {

    // MARK: - Happy path (the promised date, marker, value, unit shape)

    func testHappyPathMapsCatalogMarkers() {
        let csv = """
        date,marker,value,unit
        2026-05-01,ldl,3.1,mmol/L
        2026-05-01,Ferritin,80,µg/L
        2026-05-02,Vitamin D,72,nmol/L
        """
        let result = LabMarkerCsvImport.parse(text: csv)

        XCTAssertEqual(result.importedReadings, 3)
        XCTAssertEqual(result.skippedRows, 0)
        XCTAssertEqual(result.distinctMarkers, 3)
        XCTAssertEqual(result.earliestDay, "2026-05-01")
        XCTAssertEqual(result.latestDay, "2026-05-02")
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.fileTooLarge)
        XCTAssertTrue(result.customMarkerKeys.isEmpty)

        let ldl = result.rows.first { $0.markerKey == "ldl" }!
        XCTAssertEqual(ldl.category, .bloodPanel)
        XCTAssertEqual(ldl.value, 3.1)
        XCTAssertEqual(ldl.unit, "mmol/L")
        XCTAssertFalse(ldl.isCustomMarker)

        // Display-name matching ("Ferritin", "Vitamin D") folds onto catalog keys.
        XCTAssertTrue(result.rows.contains { $0.markerKey == "ferritin" && $0.value == 80 })
        XCTAssertTrue(result.rows.contains { $0.markerKey == "vitamin_d" && $0.value == 72 })
    }

    // MARK: - Header variants

    func testHeaderVariantsResolve() {
        let csv = """
        Day,Test,Result,Units
        2026-05-01,LDL cholesterol,3.4,mmol/L
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 1)
        XCTAssertEqual(result.rows[0].markerKey, "ldl")
        XCTAssertEqual(result.rows[0].value, 3.4)
    }

    func testSemicolonDelimitedEuropeanFileWithDecimalCommas() {
        // A European spreadsheet export: ';' delimiter (CSVTable sniffs it) and a
        // decimal COMMA in the value. "5,2" must read as 5.2, never 52.
        let csv = """
        date;marker;value;unit
        2026-05-01;fasting glucose;5,2;mmol/L
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 1)
        XCTAssertEqual(result.rows[0].markerKey, "fasting_glucose")
        XCTAssertEqual(result.rows[0].value, 5.2, accuracy: 1e-9)
    }

    func testMissingUnitColumnFallsBackToCatalogUnit() {
        let csv = """
        date,marker,value
        2026-05-01,ldl,3.1
        2026-05-01,My Own Marker,42
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.rows.first { $0.markerKey == "ldl" }?.unit, "mmol/L")
        // Custom markers have no catalog unit — empty, never invented.
        XCTAssertEqual(result.rows.first { $0.isCustomMarker }?.unit, "")
    }

    // MARK: - No silent unit conversion (the non-clinical contract)

    func testUnitIsStoredVerbatimNeverConverted() {
        let csv = """
        date,marker,value,unit
        2026-05-01,ldl,120,mg/dL
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.rows[0].value, 120)          // NOT divided by 38.67
        XCTAssertEqual(result.rows[0].unit, "mg/dL")       // exactly as written
    }

    // MARK: - Custom marker fallback (same key the manual editor mints)

    func testUnknownMarkerImportsAsCustom() {
        let csv = """
        date,marker,value,unit
        2026-05-01,Magnesium,0.84,mmol/L
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 1)
        let row = result.rows[0]
        XCTAssertEqual(row.markerKey, "custom_magnesium")   // MarkerUnits.slug parity
        XCTAssertEqual(row.category, .other)
        XCTAssertTrue(row.isCustomMarker)
        XCTAssertEqual(result.customMarkerKeys, ["custom_magnesium"])
    }

    func testCustomMarkerKeyCanonicalizesNFCAndNFDBeforeSlugging() {
        // Compare UTF-8 bytes: Swift String equality deliberately treats canonically equivalent
        // spellings as equal and would mask a decomposed persisted identifier.
        let expected: [UInt8] = [
            0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x5f, 0x63, 0x61, 0x66,
            0xc3, 0xa9, 0x5f, 0x6d, 0x61, 0x72, 0x6b, 0x65, 0x72,
        ]
        XCTAssertEqual(Array(LabMarkerCsvImport.customKey("Caf\u{e9} Marker").utf8), expected)
        XCTAssertEqual(Array(LabMarkerCsvImport.customKey("Cafe\u{301} Marker").utf8), expected)
        XCTAssertEqual(LabMarkerCsvImport.customKey("Apo B"), "custom_apo_b")
    }

    func testCanonicalEquivalentCustomMarkerRowsShareKeyAndLastRowWins() {
        let csv = """
        date,marker,value,unit
        2026-05-01,Caf\u{e9} Marker,1,mg/L
        2026-05-01,Cafe\u{301} Marker,2,mg/L
        """
        let expected: [UInt8] = [
            0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x5f, 0x63, 0x61, 0x66,
            0xc3, 0xa9, 0x5f, 0x6d, 0x61, 0x72, 0x6b, 0x65, 0x72,
        ]
        let result = LabMarkerCsvImport.parse(text: csv)

        XCTAssertEqual(result.importedReadings, 1)
        XCTAssertEqual(result.distinctMarkers, 1)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].value, 2)
        XCTAssertEqual(Array(result.rows[0].markerKey.utf8), expected)
        XCTAssertEqual(result.customMarkerKeys.count, 1)
        XCTAssertEqual(Array(result.customMarkerKeys[0].utf8), expected)
    }

    // MARK: - Blood pressure pairs (diastolic must never be dropped)

    func testCombinedBloodPressureSplitsIntoPair() {
        let csv = """
        date,marker,value,unit
        2026-05-01,Blood pressure,120/80,mmHg
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 2)
        let sys = result.rows.first { $0.markerKey == "bp_systolic" }!
        let dia = result.rows.first { $0.markerKey == "bp_diastolic" }!
        XCTAssertEqual(sys.value, 120)
        XCTAssertEqual(dia.value, 80)
        XCTAssertEqual(sys.category, .bloodPressure)
        XCTAssertEqual(sys.unit, "mmHg")
    }

    func testExplicitSystolicDiastolicRowsMap() {
        let csv = """
        date,marker,value,unit
        2026-05-01,Systolic,118,mmHg
        2026-05-01,Diastolic,76,mmHg
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 2)
        XCTAssertTrue(result.rows.contains { $0.markerKey == "bp_systolic" && $0.value == 118 })
        XCTAssertTrue(result.rows.contains { $0.markerKey == "bp_diastolic" && $0.value == 76 })
    }

    func testCombinedBpNameWithoutPairValueIsSkippedNotGuessed() {
        // "BP, 120" — there is no single marker to land a combined name on. Skip + count.
        let csv = """
        date,marker,value,unit
        2026-05-01,BP,120,mmHg
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 0)
        XCTAssertEqual(result.skippedRows, 1)
    }

    // MARK: - Bad rows are reported, never fatal

    func testBadRowsAreSkippedAndCounted() {
        let csv = """
        date,marker,value,unit
        not-a-date,ldl,3.1,mmol/L
        2026-05-01,,3.1,mmol/L
        2026-05-01,ldl,positive,mmol/L
        2026-05-01,ldl,,mmol/L
        2026-05-02,ldl,3.0,mmol/L
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 1)      // the one good row still lands
        XCTAssertEqual(result.skippedRows, 4)
        XCTAssertEqual(result.rows[0].day, "2026-05-02")
    }

    func testValueWithTrailingUnitTextParses() {
        let csv = """
        date,marker,value
        2026-05-01,ldl,3.2 mmol/L
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.rows[0].value, 3.2, accuracy: 1e-9)
    }

    // MARK: - Duplicate same-day rows: last write wins (projection parity)

    func testDuplicateSameDayLastRowWins() {
        let csv = """
        date,marker,value,unit
        2026-05-01,ldl,3.1,mmol/L
        2026-05-01,ldl,3.4,mmol/L
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 1)
        XCTAssertEqual(result.rows[0].value, 3.4)       // the later row won
    }

    // MARK: - Date variants

    func testDateVariants() {
        let csv = """
        date,marker,value
        2026-05-01 08:30,ldl,3.1
        15/01/2026,hdl,1.4
        01/15/2026,triglycerides,1.1
        2026/6/1,crp,2.0
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.skippedRows, 0)
        XCTAssertEqual(result.rows.first { $0.markerKey == "ldl" }?.day, "2026-05-01")
        // 15 > 12 forces day-first.
        XCTAssertEqual(result.rows.first { $0.markerKey == "hdl" }?.day, "2026-01-15")
        // Ambiguous 01/15 defaults to US month-first.
        XCTAssertEqual(result.rows.first { $0.markerKey == "triglycerides" }?.day, "2026-01-15")
        XCTAssertEqual(result.rows.first { $0.markerKey == "crp" }?.day, "2026-06-01")
    }

    func testImpossibleCalendarDatesAreRejected() {
        let csv = """
        date,marker,value
        2026-02-29,ldl,3.1
        2026-13-01,hdl,1.4
        """
        let result = LabMarkerCsvImport.parse(text: csv)
        XCTAssertEqual(result.importedReadings, 0)
        XCTAssertEqual(result.skippedRows, 2)
    }

    // MARK: - Import-DoS bounds

    func testRowCapTruncatesAndReports() {
        var csv = "date,marker,value\n"
        for i in 0..<10 { csv += "2026-05-0\(i % 9 + 1),ldl,3.\(i)\n" }
        let result = LabMarkerCsvImport.parseTable(CSVTable(text: csv), maxRows: 4)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.skippedRows, 6)           // the unread tail is reported
        XCTAssertLessThanOrEqual(result.importedReadings, 4)
    }

    func testOversizeFileIsRejectedOutright() {
        let oversize = Data(count: LabMarkerCsvImport.maxBytes + 1)
        let result = LabMarkerCsvImport.parse(data: oversize)
        XCTAssertTrue(result.fileTooLarge)
        XCTAssertEqual(result.importedReadings, 0)
    }

    // MARK: - Empty / garbage input

    func testEmptyAndHeaderlessInput() {
        XCTAssertEqual(LabMarkerCsvImport.parse(text: "").importedReadings, 0)
        let garbage = LabMarkerCsvImport.parse(text: "this is not\na csv at all")
        XCTAssertEqual(garbage.importedReadings, 0)
        XCTAssertEqual(garbage.skippedRows, 1)          // the one data line, reported
    }

    // MARK: - Helper grammar pins (byte-identical to the Kotlin twin)

    func testParseValueGrammar() {
        XCTAssertEqual(LabMarkerCsvImport.parseValue("3.1"), 3.1)
        XCTAssertEqual(LabMarkerCsvImport.parseValue("5,2"), 5.2)          // decimal comma
        XCTAssertEqual(LabMarkerCsvImport.parseValue("1,234"), 1234)      // thousands group
        XCTAssertEqual(LabMarkerCsvImport.parseValue("62 ms"), 62)        // stray unit
        XCTAssertNil(LabMarkerCsvImport.parseValue("120/80"))              // pairs never parse here
        XCTAssertNil(LabMarkerCsvImport.parseValue("negative"))
        XCTAssertNil(LabMarkerCsvImport.parseValue(""))
    }

    /// Adversarial value grammar (the CSV-import edge finding). A zero-integer-part decimal comma with
    /// exactly 3 decimals is a DECIMAL comma, never a thousands group ("0,500" is 0.5, not 500), and
    /// non-finite tokens (NaN / Infinity spellings, 1e999 overflow) are REJECTED so nothing non-finite
    /// reaches the store or the chart math.
    func testParseValueRejectsThousandGroupForZeroLedDecimalComma() {
        XCTAssertEqual(LabMarkerCsvImport.parseValue("0,500"), 0.5)        // was 500 (1000x too large)
        XCTAssertEqual(LabMarkerCsvImport.parseValue("0,95"), 0.95)
        XCTAssertEqual(LabMarkerCsvImport.parseValue("1,500"), 1500)      // genuine thousands group stays
        XCTAssertEqual(LabMarkerCsvImport.parseValue("12,345"), 12345)    // 3-digit non-zero-led = thousands
    }

    func testParseValueRejectsNonFinite() {
        XCTAssertNil(LabMarkerCsvImport.parseValue("nan"))
        XCTAssertNil(LabMarkerCsvImport.parseValue("NaN"))
        XCTAssertNil(LabMarkerCsvImport.parseValue("inf"))
        XCTAssertNil(LabMarkerCsvImport.parseValue("Infinity"))
        XCTAssertNil(LabMarkerCsvImport.parseValue("-Infinity"))
        XCTAssertNil(LabMarkerCsvImport.parseValue("1e999"))              // overflows to +Inf
    }

    func testCustomKeyMirrorsManualEditorSlug() {
        XCTAssertEqual(LabMarkerCsvImport.customKey("Magnesium"), "custom_magnesium")
        XCTAssertEqual(LabMarkerCsvImport.customKey("Apo B"), "custom_apo_b")
        XCTAssertEqual(LabMarkerCsvImport.customKey("  ???  "), "")
    }
}
