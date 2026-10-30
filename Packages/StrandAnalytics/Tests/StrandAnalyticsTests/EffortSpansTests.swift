import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Effort's workout time (#2438): below 50 % HRR a reading counts only inside a recorded workout or a detected
/// bout, and a detected bout the wearer dismissed is not one (`AnalyticsEngine.effortSpans`).
final class EffortSpansTests: XCTestCase {

    private func bout(_ start: Int, _ end: Int) -> ExerciseSession {
        ExerciseSession(start: start, end: end, avgHR: 120, peakHR: 140, strain: nil,
                        durationS: Double(end - start), zoneTimePct: [:], avgHRRPct: nil, hrmax: nil,
                        hrmaxSource: "test", caloriesKcal: nil, caloriesKJ: nil)
    }

    func testADismissedBoutLeavesTheSpansAndARecordedWorkoutStays() {
        let spans = AnalyticsEngine.effortSpans(workouts: [1_000 ..< 2_000],
                                                detected: [bout(1_500, 2_500), bout(5_000, 6_000), bout(7_000, 8_000)],
                                                dismissed: [1_400 ..< 1_600, 6_000 ..< 6_500])
        // The recorded workout overlaps a dismissal and stays: only detected bouts can be dismissed. A
        // dismissal that only touches a bout's end (half-open) leaves it.
        XCTAssertEqual(spans, [1_000 ..< 2_000, 5_000 ..< 6_000, 7_000 ..< 8_000])
    }

    /// A walk whose warm-up runs below 50 % HRR: inside the detected bout that warm-up is workout time and
    /// raises the day's Effort; once the bout is dismissed it no longer does.
    func testDismissingADetectedBoutTakesItsLowIntensityTimeOutOfEffort() throws {
        let start = 20_000_000
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for t in (start - 1_800) ..< (start + 35 * 60 + 1_800) {
            let warm = t >= start && t < start + 15 * 60
            let core = t >= start + 15 * 60 && t < start + 35 * 60
            hr.append(HRSample(ts: t, bpm: core ? 155 : (warm ? 100 : 52)))
            gravity.append(GravitySample(ts: t, x: (warm || core) ? Double(t % 2) * 0.5 : 0, y: 0, z: 1))
        }
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let bouts = AnalyticsEngine.detectDayBouts(hr: hr, gravity: gravity, restingHR: 52, maxHR: 185,
                                                   profile: profile)
        let detected = try XCTUnwrap(bouts.first)
        XCTAssertEqual(bouts.count, 1)
        XCTAssertLessThanOrEqual(detected.start, start + 120, "the bout covers the warm-up")

        func effort(dismissed: [Range<Int>]) -> Double? {
            StrainScorer.strain(hr, maxHR: 185, restingHR: 52, lowIntensity: .countedIn(
                AnalyticsEngine.effortSpans(workouts: [], detected: bouts, dismissed: dismissed)))
        }
        let kept = try XCTUnwrap(effort(dismissed: []))
        let dismissed = try XCTUnwrap(effort(dismissed: [detected.start ..< detected.start + 60]))
        XCTAssertGreaterThan(kept, dismissed)
        XCTAssertEqual(dismissed, try XCTUnwrap(StrainScorer.strain(hr, maxHR: 185, restingHR: 52,
                                                                    lowIntensity: .countedIn([]))),
                       accuracy: 1e-9, "a dismissed bout counts exactly like no workout")
    }
}
