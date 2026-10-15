import XCTest
@testable import Strand

/// The screens read the newest stored day of the daily rhythm pass, and only that day: an older reading
/// must not stand in for a newer day that is still collecting.
final class RhythmAgeSnapshotTests: XCTestCase {

    private typealias K = IntelligenceEngine

    func testTheNewestScoredDayIsShown() {
        let s = RhythmAgeSnapshot.latest([
            K.rhythmHoursKey: ["2026-10-14": 160, "2026-10-15": 165],
            K.rhythmAdvanceKey: ["2026-10-14": 8.5, "2026-10-15": 9.1],
            K.rhythmMesorKey: ["2026-10-15": 15.8],
            K.rhythmAmplitudeKey: ["2026-10-15": 9.3],
            K.rhythmPeakKey: ["2026-10-15": 13.2],
            K.rhythmHourKey(9): ["2026-10-14": 5, "2026-10-15": 37.4],
            K.rhythmHourKey(10): ["2026-10-15": 39.8],
        ])
        guard case .reading(let r) = s else { return XCTFail("expected a reading") }
        XCTAssertEqual(r.hourly.count, 24)
        XCTAssertEqual(r.hourly[9]!, 37.4, accuracy: 1e-9, "the hours come from the same day as the reading")
        XCTAssertNil(r.hourly[11])
        XCTAssertEqual(r.day, "2026-10-15")
        XCTAssertEqual(r.advance, 9.1, accuracy: 1e-9)
        XCTAssertEqual(r.peakHour, 13.2, accuracy: 1e-9)
    }

    func testANewerCollectingDayIsNotCoveredByAnOlderReading() {
        let s = RhythmAgeSnapshot.latest([
            K.rhythmHoursKey: ["2026-10-14": 160, "2026-10-15": 40],
            K.rhythmAdvanceKey: ["2026-10-14": 8.5],
            K.rhythmMesorKey: ["2026-10-14": 15.8],
            K.rhythmAmplitudeKey: ["2026-10-14": 9.3],
            K.rhythmPeakKey: ["2026-10-14": 13.2],
        ])
        XCTAssertEqual(s, .collecting(hours: 40))
    }

    func testNothingStoredIsEmpty() {
        XCTAssertEqual(RhythmAgeSnapshot.latest([:]), .empty)
    }
}
