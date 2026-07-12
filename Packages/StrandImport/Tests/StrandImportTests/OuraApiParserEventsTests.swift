import XCTest
@testable import StrandImport

final class OuraApiParserEventsTests: XCTestCase {
    func testWorkoutParse() throws {
        let w = OuraApiParser.parseWorkouts([[
            "activity": "running", "source": "autodetected",
            "start_datetime": "2026-01-02T07:00:00+00:00", "end_datetime": "2026-01-02T07:40:00+00:00",
            "calories": 410, "distance": 6200
        ]])
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.first?.activity, "running")
        XCTAssertEqual(w.first?.source, "autodetected")
        XCTAssertEqual(w.first?.energyKcal, 410)
        XCTAssertEqual(w.first?.distanceM, 6200)
    }

    func testHeartRatePageParseDropsNonPositive() {
        let hr = OuraApiParser.parseHeartRate([
            ["timestamp": "2026-01-02T07:00:00+00:00", "bpm": 120, "source": "workout"],
            ["timestamp": "2026-01-02T07:05:00+00:00", "bpm": 0,   "source": "workout"]   // dropped
        ])
        XCTAssertEqual(hr.map(\.bpm), [120])
        XCTAssertEqual(hr.first?.ts, Int(ISO8601DateFormatter().date(from: "2026-01-02T07:00:00Z")!.timeIntervalSince1970))
    }
}
