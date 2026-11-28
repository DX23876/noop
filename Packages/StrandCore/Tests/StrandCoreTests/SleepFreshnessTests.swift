import XCTest
import StrandCore

final class SleepFreshnessTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }

    private func at(_ hour: Int, day: Int = 28) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testANightThatEndedTodaySilencesEverythingButASync() {
        let wake = Int(at(7).timeIntervalSince1970)
        XCTAssertNil(SleepFreshness.resolve(latestWakeTs: wake, now: at(9), calendar: calendar, syncing: false,
                                            calculating: true, lastSyncedAt: nil, syncFailed: true))
        XCTAssertEqual(SleepFreshness.resolve(latestWakeTs: wake, now: at(9), calendar: calendar, syncing: true,
                                              calculating: false, lastSyncedAt: nil, syncFailed: false), .syncing)
    }

    func testAMissingNightWaitsForMorningThenSaysWhy() {
        let yesterday = Int(at(7, day: 27).timeIntervalSince1970)
        XCTAssertNil(SleepFreshness.resolve(latestWakeTs: yesterday, now: at(3), calendar: calendar, syncing: false,
                                            calculating: false, lastSyncedAt: nil, syncFailed: false))
        XCTAssertEqual(SleepFreshness.resolve(latestWakeTs: yesterday, now: at(3), calendar: calendar, syncing: false,
                                              calculating: true, lastSyncedAt: nil, syncFailed: false), .calculating)
        XCTAssertEqual(SleepFreshness.resolve(latestWakeTs: yesterday, now: at(9), calendar: calendar, syncing: false,
                                              calculating: false, lastSyncedAt: nil, syncFailed: true), .syncFailed)
        XCTAssertEqual(SleepFreshness.resolve(latestWakeTs: yesterday, now: at(9), calendar: calendar, syncing: false,
                                              calculating: false, lastSyncedAt: at(1, day: 27).timeIntervalSince1970,
                                              syncFailed: false), .awaitingSync)
        XCTAssertEqual(SleepFreshness.resolve(latestWakeTs: nil, now: at(9), calendar: calendar, syncing: false,
                                              calculating: false, lastSyncedAt: at(8).timeIntervalSince1970,
                                              syncFailed: false), .notDetected)
    }
}
