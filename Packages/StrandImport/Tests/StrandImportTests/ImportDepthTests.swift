import XCTest
@testable import StrandImport

/// Pins the steps against the Kotlin twin (`ImportDepthTest.kt`), which asserts the same four months.
final class ImportDepthTests: XCTestCase {

    func testTheDefaultIsAYear() {
        XCTAssertEqual(ImportDepth.default, .oneYear)
        XCTAssertEqual(ImportDepth.default.months, 12)
    }

    func testTheStepsMatchTheKotlinTwin() {
        XCTAssertEqual(ImportDepth.allCases.map(\.months), [1, 12, 36, 120])
    }

    func testTheDaysAreWholeDaysBackFromToday() {
        XCTAssertEqual(ImportDepth.oneMonth.days, 30)
        XCTAssertEqual(ImportDepth.oneYear.days, 365)
        XCTAssertEqual(ImportDepth.threeYears.days, 1_095)
        // The longest step stays the ten-year lookback the full-history import has always used.
        XCTAssertEqual(ImportDepth.tenYears.days, 3_650)
    }

    func testAStoredMonthCountResolvesToItsStep() {
        for step in ImportDepth.allCases {
            XCTAssertEqual(ImportDepth.ofMonths(step.months), step)
        }
    }

    func testAStoredValueFromAnotherSetOfStepsFallsBackRatherThanFailing() {
        XCTAssertEqual(ImportDepth.ofMonths(6), .default)
        XCTAssertEqual(ImportDepth.ofMonths(0), .default)
        XCTAssertEqual(ImportDepth.ofMonths(-1), .default)
        XCTAssertEqual(ImportDepth.ofMonths(Int.max), .default)
    }
}
