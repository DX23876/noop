import XCTest
@testable import StrandCore

final class HevyAutoImportTests: XCTestCase {
    private let hour = 3_600

    func testEachIntervalIsDueAfterItsTimeAndAWakeALittleEarlyCounts() {
        let now = 1_000_000
        for interval in HevyAutoImport.Interval.allCases where interval != .off {
            let seconds = interval.seconds!
            XCTAssertTrue(HevyAutoImport.isDue(lastRun: now - seconds, now: now, interval: interval), "\(interval)")
            XCTAssertTrue(HevyAutoImport.isDue(lastRun: now - seconds * 9 / 10, now: now, interval: interval),
                          "a wake a tenth early still runs: \(interval)")
            XCTAssertFalse(HevyAutoImport.isDue(lastRun: now - seconds / 2, now: now, interval: interval),
                           "half way is not due: \(interval)")
        }
    }

    func testNeverRunIsDueAndOffNeverIs() {
        XCTAssertTrue(HevyAutoImport.isDue(lastRun: nil, now: 10, interval: .daily))
        XCTAssertFalse(HevyAutoImport.isDue(lastRun: nil, now: 10, interval: .off))
        XCTAssertNil(HevyAutoImport.nextDue(lastRun: 0, now: 10, interval: .off))
        // A last run stamped in the future (a clock moved back) does not block the import for good.
        XCTAssertTrue(HevyAutoImport.isDue(lastRun: 500, now: 10, interval: .sixHours))
    }

    func testNextDueIsTheEarliestRunnableMoment() {
        let last = 100_000
        XCTAssertEqual(HevyAutoImport.nextDue(lastRun: last, now: last + hour, interval: .sixHours),
                       last + 6 * hour - 6 * hour / 10)
        XCTAssertEqual(HevyAutoImport.nextDue(lastRun: last, now: last + 30 * hour, interval: .daily), last + 30 * hour)
        XCTAssertEqual(HevyAutoImport.nextDue(lastRun: nil, now: 7, interval: .twelveHours), 7)
    }

    func testStoredChoiceAndWhatNeedsTheWearer() {
        XCTAssertEqual(HevyAutoImport.interval(nil), .off, "opt-in, as every automation that reaches the network")
        XCTAssertEqual(HevyAutoImport.interval("6h"), .sixHours)
        XCTAssertEqual(HevyAutoImport.interval("garbage"), .off)
        XCTAssertTrue(HevyAutoImport.needsWearer("unauthorized"))
        XCTAssertTrue(HevyAutoImport.needsWearer("notPro"))
        XCTAssertFalse(HevyAutoImport.needsWearer("network"))
        XCTAssertFalse(HevyAutoImport.needsWearer(nil))
    }
}
