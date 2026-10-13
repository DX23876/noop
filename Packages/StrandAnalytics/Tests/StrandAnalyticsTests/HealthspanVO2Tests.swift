import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HealthspanVO2Tests: XCTestCase {

    private typealias V = HealthspanVO2
    private let end = "2026-10-10"

    /// An entered value wins for a year from the day it was measured, and never before that day, while fewer than
    /// two newer measurements exist.
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

    /// Apple Health leads while it measured in the last 30 days; the age takes the six-month median.
    func testAppleBeforeTrainingWithMedian() {
        let apple = [(day: "2026-05-01", value: 40.0), (day: "2026-07-01", value: 44.0), (day: "2026-09-20", value: 41.0),
                     (day: "2026-01-01", value: 99.0)]   // older than six months: ignored
        let training = [(day: "2026-10-01", value: 30.0)]
        let r = V.resolve(manual: nil, appleHealth: apple, training: training, endingOn: end)!
        XCTAssertEqual(r.source, .appleHealth)
        XCTAssertEqual(r.window, 41)
        XCTAssertEqual(r.readings, 3)
        XCTAssertEqual(V.resolve(manual: nil, appleHealth: [], training: training, endingOn: end)!.source, .training)
        XCTAssertNil(V.resolve(manual: nil, appleHealth: [], training: [], endingOn: end))
    }

    /// A watch that stopped measuring does not hide this month's walks and runs; without any, its older readings
    /// still count.
    func testStaleAppleGivesWayToWalksAndRuns() {
        let apple = [(day: "2026-06-01", value: 44.0), (day: "2026-08-01", value: 46.0)]
        let training = [(day: "2026-09-01", value: 38.0), (day: "2026-10-01", value: 40.0)]
        let r = V.resolve(manual: nil, appleHealth: apple, training: training, endingOn: end)!
        XCTAssertEqual(r.source, .training)
        XCTAssertEqual(r.window, 39)
        let old = V.resolve(manual: nil, appleHealth: apple, training: [], endingOn: end)!
        XCTAssertEqual(old.source, .appleHealth)
        XCTAssertEqual(old.window, 45)
    }

    /// Two measurements newer than an entry replace it, and only readings after the entry count from then on.
    func testTwoNewerReadingsReplaceAnEntry() {
        let manual = (day: "2026-09-01", value: 52.0)
        var training = [(day: "2026-07-01", value: 30.0), (day: "2026-09-10", value: 44.0)]
        var r = V.resolve(manual: manual, appleHealth: [], training: training, endingOn: end)!
        XCTAssertEqual(r.source, .manual)
        XCTAssertEqual(r.window, 52)
        training.append((day: "2026-10-05", value: 46.0))
        r = V.resolve(manual: manual, appleHealth: [], training: training, endingOn: end)!
        XCTAssertEqual(r.source, .training)
        XCTAssertEqual(r.window, 45)      // 44 and 46; the July walk before the entry no longer counts
        XCTAssertEqual(r.readings, 2)
        XCTAssertEqual(r.recent, 45)
        XCTAssertEqual(r.latestDay, "2026-10-05")
        // The same day a week earlier still had only one newer reading: the entry stood.
        XCTAssertEqual(V.resolve(manual: manual, appleHealth: [], training: training, endingOn: "2026-10-04")!.source,
                       .manual)
    }

    /// A goal follows the readings of the source the resolver chose: the entry while it stands, else the
    /// measurements after it.
    func testGoalReadings() {
        let manual = (day: "2026-09-01", value: 52.0)
        let training = [(day: "2026-07-01", value: 30.0), (day: "2026-09-10", value: 44.0)]
        XCTAssertEqual(V.goalReadings(manual: manual, appleHealth: [], training: training, today: end).map(\.value), [52])
        let more = training + [(day: "2026-10-05", value: 46.0)]
        XCTAssertEqual(V.goalReadings(manual: manual, appleHealth: [], training: more, today: end).map(\.day),
                       ["2026-09-10", "2026-10-05"])
        XCTAssertEqual(V.goalReadings(manual: nil, appleHealth: [], training: more, today: end).count, 3)
        XCTAssertTrue(V.goalReadings(manual: nil, appleHealth: [], training: [], today: end).isEmpty)
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
