import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HealthspanVO2Tests: XCTestCase {

    private typealias V = HealthspanVO2
    private let end = "2026-10-10"

    /// An entered value (a lab test) wins for a year from the day it was measured, and never before that day.
    func testManualWinsForAYear() {
        let apple = [(day: "2026-10-01", value: 40.0), (day: "2026-10-05", value: 41.0), (day: "2026-10-08", value: 42.0)]
        let r = V.resolve(manual: (day: "2026-01-15", value: 52), appleHealth: apple, endingOn: end)!
        XCTAssertEqual(r.source, .manual)
        XCTAssertEqual(r.window, 52)
        XCTAssertEqual(r.recent, 52)
        XCTAssertEqual(V.resolve(manual: (day: "2025-10-10", value: 52), appleHealth: apple, endingOn: end)!.source,
                       .appleHealth)
        XCTAssertEqual(V.resolve(manual: (day: "2026-10-11", value: 52), appleHealth: apple, endingOn: end)!.source,
                       .appleHealth)
    }

    /// Apple Health counts over the whole six-month window, however long ago the watch last measured; the age
    /// takes the median.
    func testAppleCountsForSixMonths() {
        let apple = [(day: "2026-05-01", value: 40.0), (day: "2026-07-01", value: 44.0), (day: "2026-08-24", value: 41.0),
                     (day: "2026-01-01", value: 99.0)]   // older than six months: ignored
        let r = V.resolve(manual: nil, appleHealth: apple, endingOn: end)!
        XCTAssertEqual(r.source, .appleHealth)
        XCTAssertEqual(r.window, 41)
        XCTAssertEqual(r.readings, 3)
        XCTAssertEqual(r.latestDay, "2026-08-24")
        XCTAssertNil(V.resolve(manual: nil, appleHealth: [], endingOn: end), "no measurement, no VO₂max")
    }

    /// The pace takes the last 30 days only from two readings on; one reading falls back to the six months.
    func testRecentNeedsTwoReadings() {
        var apple = [(day: "2026-06-01", value: 40.0), (day: "2026-07-01", value: 40.0), (day: "2026-10-05", value: 46.0)]
        var r = V.resolve(manual: nil, appleHealth: apple, endingOn: end)!
        XCTAssertEqual(r.window, 40)
        XCTAssertEqual(r.recent, 40)
        apple.append((day: "2026-10-08", value: 48.0))
        r = V.resolve(manual: nil, appleHealth: apple, endingOn: end)!
        XCTAssertEqual(r.recent, 47)
    }

    /// A goal follows the entry while it counts, else every Apple Health reading.
    func testGoalReadings() {
        let apple = [(day: "2026-09-10", value: 44.0), (day: "2026-07-01", value: 30.0), (day: "2026-10-20", value: 50.0)]
        XCTAssertEqual(V.goalReadings(manual: (day: "2026-09-01", value: 52), appleHealth: apple, today: end)
            .map(\.value), [52])
        XCTAssertEqual(V.goalReadings(manual: nil, appleHealth: apple, today: end).map(\.day), ["2026-07-01", "2026-09-10"])
        XCTAssertTrue(V.goalReadings(manual: nil, appleHealth: [], today: end).isEmpty)
    }

    /// Long sessions bound VO₂max from below: an hour or more at a pace costs at most 60 % of it.
    func testEnduranceFloor() throws {
        // 134 minutes over 8.8 km, flat: about 65.7 m/min, ACSM cost 10.07 ml/kg/min.
        let cost = try XCTUnwrap(V.longSessionCost(distanceM: 8_800, durationS: 134 * 60, ascentM: nil))
        XCTAssertEqual(cost, 0.1 * 8_800 / 134 + 3.5, accuracy: 1e-9)
        // A measured climb raises the cost by the ACSM uphill term.
        let hilly = try XCTUnwrap(V.longSessionCost(distanceM: 8_800, durationS: 134 * 60, ascentM: 134))
        XCTAssertEqual(hilly - cost, 1.8, accuracy: 1e-9)
        XCTAssertNil(V.longSessionCost(distanceM: 3_000, durationS: 45 * 60, ascentM: nil), "under an hour")
        XCTAssertNil(V.longSessionCost(distanceM: 48, durationS: 70 * 60, ascentM: nil), "no walking speed")
        let sessions = [V.LongSession(day: "2026-09-20", oxygenCost: 10.0), V.LongSession(day: "2026-09-25", oxygenCost: 9.8),
                        V.LongSession(day: "2026-09-27", oxygenCost: 9.9), V.LongSession(day: "2026-01-01", oxygenCost: 30)]
        XCTAssertEqual(try XCTUnwrap(V.enduranceFloor(sessions, endingOn: end)), 9.9 / 0.6, accuracy: 1e-9)
        XCTAssertNil(V.enduranceFloor(Array(sessions.prefix(2)), endingOn: end), "fewer than three in six months")
    }

    /// Lean mass from the latest body-fat reading of the past year.
    func testLeanMassFromBodyFat() {
        let fat = [(day: "2025-09-01", value: 10.0), (day: "2026-03-01", value: 24.0), (day: "2026-08-01", value: 22.0),
                   (day: "2026-11-01", value: 30.0)]
        XCTAssertEqual(V.leanMassPct(bodyFat: fat, endingOn: end)!, 78, accuracy: 1e-9)
        XCTAssertNil(V.leanMassPct(bodyFat: [(day: "2025-01-01", value: 20.0)], endingOn: end))
    }

    /// The band's average over a session, only when its trace covers most of it.
    func testBandAverageNeedsCoverage() {
        let hr = (0..<1200).map { HRSample(ts: 1_000 + $0, bpm: $0 < 600 ? 100 : 120) }
        XCTAssertEqual(V.bandAverageHR(hr, sessionSeconds: 1200)!, 110, accuracy: 0.5)
        XCTAssertNil(V.bandAverageHR(Array(hr.prefix(600)), sessionSeconds: 1200))
        XCTAssertNil(V.bandAverageHR([], sessionSeconds: 1200))
    }
}
