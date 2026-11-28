import XCTest
import WhoopStore

final class DayKeyCalendarTests: XCTestCase {
    /// A Thai iPhone's default calendar: today reads as Buddhist year 2569.
    private var buddhist: Calendar {
        var cal = Calendar(identifier: .buddhist)
        cal.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        cal.firstWeekday = 1
        return cal
    }

    func testDayKeysStayGregorianOnABuddhistDevice() throws {
        let noon = Date(timeIntervalSince1970: 1_795_842_000)   // 2026-11-28 05:00 UTC, noon in Bangkok
        XCTAssertEqual(buddhist.component(.year, from: noon), 2569, "the device calendar really is Buddhist")
        let keys = buddhist.gregorianForDayKeys
        let c = keys.dateComponents([.year, .month, .day], from: noon)
        XCTAssertEqual([c.year, c.month, c.day], [2026, 11, 28])
        let parsed = try XCTUnwrap(keys.date(from: DateComponents(year: 2026, month: 11, day: 28)))
        XCTAssertEqual(parsed.timeIntervalSince(noon), -12 * 3_600, accuracy: 1, "midnight in Bangkok, not in 1483")
        XCTAssertEqual(keys.timeZone, buddhist.timeZone)
        XCTAssertEqual(keys.firstWeekday, 1)
    }

    func testAGregorianCalendarIsKeptAsItIs() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(cal.gregorianForDayKeys, cal)
    }
}
