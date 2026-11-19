import GRDB
import XCTest
@testable import NoopCore

/// The ceiling on one `sql.query` answer (`CoreSql.maxRows`, `CoreSql.maxValueBytes`).
///
/// Reads across the bridge had none: the host asks for up to 200,000 sample rows, every row is gathered
/// here, encoded into one string, copied onto the Java heap and parsed there again, so the same rows exist
/// four times at the peak. Writes have been chunked since they were written. The tester report of
/// 2026-11-19 died on a 592-byte allocation with the heap at its limit, which says nothing about what
/// filled it — a refused read with a message is the version of that failure somebody can act on.
final class CoreSqlLimitTests: XCTestCase {

    /// The size estimate only decides whether an answer has run away, so it has to be in the right order
    /// of magnitude for each kind of value, not exact.
    func testSizeEstimatePerValueKind() {
        XCTAssertEqual(CoreSql.size(DatabaseValue.null), 4)
        XCTAssertEqual(CoreSql.size(42.databaseValue), 8)
        XCTAssertEqual(CoreSql.size(1.5.databaseValue), 8)
        XCTAssertEqual(CoreSql.size("abc".databaseValue), 5)
        // Base64 is four characters per three bytes, plus the {"b64":""} around it.
        XCTAssertEqual(CoreSql.size(Data(repeating: 0, count: 300).databaseValue), 409)
    }

    /// A row of a sample table weighs what the ceiling assumes it weighs: the limits have to be far above
    /// an honest screen read (a day of heart rate is a few thousand rows) and below a runaway one.
    func testTheCeilingSitsAboveAnyHonestScreenRead() {
        let row = ["my-whoop".databaseValue, 1_762_000_000.databaseValue, 64.databaseValue, 0.databaseValue]
        let bytesPerRow = row.reduce(0) { $0 + CoreSql.size($1) }
        XCTAssertEqual(bytesPerRow, 34)
        // A full day of per-second heart rate, the densest thing a screen asks for.
        let dayOfSeconds = 86_400
        XCTAssertLessThan(dayOfSeconds, CoreSql.maxRows)
        XCTAssertLessThan(dayOfSeconds * bytesPerRow, CoreSql.maxValueBytes)
        // And the host's own largest limit still fits, so the ceiling only catches what no screen asks for.
        XCTAssertLessThan(200_000 * bytesPerRow, CoreSql.maxValueBytes)
    }
}
