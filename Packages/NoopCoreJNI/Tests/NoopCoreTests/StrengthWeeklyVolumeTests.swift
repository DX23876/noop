import XCTest
@testable import NoopCore

final class StrengthWeeklyVolumeTests: XCTestCase {
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Wednesday 2026-11-11 12:00 UTC; the running week starts Monday 2026-11-09.
    private let now = Date(timeIntervalSince1970: 1_794_398_400)
    private func ts(_ iso: String) -> Int {
        Int(ISO8601DateFormatter().date(from: iso + "T10:00:00Z")!.timeIntervalSince1970)
    }

    func testFinishedWeeksOnlyOldestFirst() {
        let sessions = [
            StrengthWeeklyVolume.Session(startTs: ts("2026-11-10"), volumeKg: 9_000),  // running week: left out
            StrengthWeeklyVolume.Session(startTs: ts("2026-11-08"), volumeKg: 2_000),  // Sunday of last week
            StrengthWeeklyVolume.Session(startTs: ts("2026-11-03"), volumeKg: 1_500),  // last week too
            StrengthWeeklyVolume.Session(startTs: ts("2026-09-15"), volumeKg: 4_000),  // eight weeks back
            StrengthWeeklyVolume.Session(startTs: ts("2026-09-08"), volumeKg: 7_000),  // nine weeks back: left out
        ]
        let tonnes = StrengthWeeklyVolume.tonnes(sessions, now: now, firstWeekday: 2, calendar: utc)
        XCTAssertEqual(tonnes, [4, 0, 0, 0, 0, 0, 0, 3.5])
    }

    func testSundayWeekStartMovesTheSunday() {
        let sessions = [StrengthWeeklyVolume.Session(startTs: ts("2026-11-08"), volumeKg: 2_000)]
        // With weeks starting on Sunday, 2026-11-08 opens the running week.
        XCTAssertEqual(StrengthWeeklyVolume.tonnes(sessions, now: now, firstWeekday: 1, calendar: utc), Array(repeating: 0, count: 8))
    }

    func testFourWeekChange() {
        XCTAssertEqual(StrengthWeeklyVolume.fourWeekChange([1, 1, 1, 1, 1.5, 1.5, 1.5, 1.5]), 50)
        XCTAssertEqual(StrengthWeeklyVolume.fourWeekChange([2, 2, 2, 2, 1, 1, 1, 1]), -50)
        XCTAssertNil(StrengthWeeklyVolume.fourWeekChange([0, 0, 0, 0, 1, 1, 1, 1]))
        XCTAssertNil(StrengthWeeklyVolume.fourWeekChange([1, 1, 1]))
    }
}
