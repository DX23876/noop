import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HealthspanVO2Tests: XCTestCase {

    private typealias V = HealthspanVO2
    private let end = "2026-10-10"

    /// An entered value wins for a year from the day it was measured, and never before that day.
    func testManualWinsForAYear() {
        let apple = [(day: "2026-10-01", value: 40.0)]
        let r = V.resolve(manual: (day: "2026-01-15", value: 52), appleHealth: apple, training: [], endingOn: end)!
        XCTAssertEqual(r.source, .manual)
        XCTAssertEqual(r.window, 52)
        XCTAssertEqual(r.recent, 52)
        XCTAssertEqual(V.resolve(manual: (day: "2025-10-10", value: 52), appleHealth: apple, training: [],
                                 endingOn: end)!.source, .appleHealth)
        XCTAssertEqual(V.resolve(manual: (day: "2026-10-11", value: 52), appleHealth: apple, training: [],
                                 endingOn: end)!.source, .appleHealth)
    }

    /// Apple Health before the training estimate; the age takes the six-month median.
    func testAppleBeforeTrainingWithMedian() {
        let apple = [(day: "2026-05-01", value: 40.0), (day: "2026-07-01", value: 44.0), (day: "2026-09-01", value: 41.0),
                     (day: "2026-01-01", value: 99.0)]   // older than six months: ignored
        let training = [(day: "2026-10-01", value: 30.0)]
        let r = V.resolve(manual: nil, appleHealth: apple, training: training, endingOn: end)!
        XCTAssertEqual(r.source, .appleHealth)
        XCTAssertEqual(r.window, 41)
        XCTAssertEqual(r.readings, 3)
        XCTAssertEqual(V.resolve(manual: nil, appleHealth: [], training: training, endingOn: end)!.source, .training)
        XCTAssertNil(V.resolve(manual: nil, appleHealth: [], training: [], endingOn: end))
    }

    /// The pace takes the last 30 days only from two readings on; one reading falls back to the six months.
    func testRecentNeedsTwoReadings() {
        var training = [(day: "2026-06-01", value: 40.0), (day: "2026-07-01", value: 40.0),
                        (day: "2026-10-05", value: 46.0)]
        var r = V.resolve(manual: nil, appleHealth: [], training: training, endingOn: end)!
        XCTAssertEqual(r.window, 40)
        XCTAssertEqual(r.recent, 40)
        training.append((day: "2026-10-08", value: 48.0))
        r = V.resolve(manual: nil, appleHealth: [], training: training, endingOn: end)!
        XCTAssertEqual(r.recent, 47)
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
