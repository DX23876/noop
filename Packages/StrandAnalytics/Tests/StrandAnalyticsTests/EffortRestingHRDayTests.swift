import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The day pass scores Effort against `EffortRestingHR` (halfway between the night's lowest five minutes and its
/// mean) while the day keeps showing the lowest five minutes, and a detected bout is found on the day's baseline but scored on Effort's.
final class EffortRestingHRDayTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2026-07-27"

    private func hr(_ start: Int, _ end: Int, bpm: Int, every step: Int = 30,
                    dip: (start: Int, end: Int, bpm: Int)? = nil) -> [HRSample] {
        stride(from: start, to: end, by: step).map { ts in
            if let dip, ts >= dip.start, ts < dip.end { return HRSample(ts: ts, bpm: dip.bpm) }
            return HRSample(ts: ts, bpm: bpm)
        }
    }

    private func session(_ start: Int, _ end: Int) -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 0.9,
                     stages: [StageSegment(start: start, end: end, stage: "light")],
                     restingHR: nil, avgHRV: nil)
    }

    /// A night at 60 bpm with a 10-minute dip to 50, then an hour at 140 bpm in the afternoon.
    func testTheDaysEffortIsScoredAgainstTheNightsMean() throws {
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let nightStart = dayStart - 4 * 3600, nightEnd = nightStart + 8 * 3600
        let dipStart = nightStart + 300 * 60
        let night = session(nightStart, nightEnd)
        let samples = hr(nightStart, nightEnd, bpm: 60, dip: (dipStart, dipStart + 600, 50))
            + hr(dayStart + 14 * 3600, dayStart + 15 * 3600, bpm: 140)
        let res = AnalyticsEngine.analyzeDay(day: day, hr: samples, rr: [], profile: profile,
                                             providedSleep: [night], recentNightRHR: [70, 70, 70])

        let mean = try XCTUnwrap(AnalyticsEngine.primarySessionRestingHR(sessions: [night], hr: samples))
        let halfway = 50 + (mean - 50) / 2
        XCTAssertEqual(res.daily.restingHr, 50, "the day still shows the night's lowest five minutes")
        XCTAssertEqual(res.effortRestingHR, halfway, accuracy: 1e-9, "Effort reads halfway to the night's mean")
        let maxHR = MaxHeartRate.resolve(override: nil, age: profile.age).bpm
        let expected = try XCTUnwrap(StrainScorer.strain(samples, maxHR: maxHR, restingHR: halfway,
                                                         lowIntensity: .day(workouts: [])))
        XCTAssertEqual(try XCTUnwrap(res.strain), expected, accuracy: 1e-9)
        let onTheNadir = try XCTUnwrap(StrainScorer.strain(samples, maxHR: maxHR, restingHR: 50,
                                                           lowIntensity: .day(workouts: [])))
        XCTAssertLessThan(expected, onTheNadir, "the higher resting heart rate lowers the day")
    }

    /// A day with no night takes the median of the nights before it.
    func testWithoutANightTheNightsBeforeStandIn() {
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let samples = hr(dayStart + 10 * 3600, dayStart + 12 * 3600, bpm: 110)
        let res = AnalyticsEngine.analyzeDay(day: day, hr: samples, rr: [], profile: profile,
                                             recentNightRHR: [80, 70, 72, 74])
        XCTAssertNil(res.daily.restingHr)
        XCTAssertEqual(res.effortRestingHR, 73, accuracy: 1e-9)
    }

    /// The same walk found with and without Effort's resting heart rate: the same bout, scored on Effort's.
    func testABoutIsFoundOnTheDaysBaselineAndScoredOnEfforts() throws {
        let start = 20_000_000
        var samples: [HRSample] = []
        var gravity: [GravitySample] = []
        for t in (start - 1_800) ..< (start + 35 * 60 + 1_800) {
            let warm = t >= start && t < start + 15 * 60
            let core = t >= start + 15 * 60 && t < start + 35 * 60
            samples.append(HRSample(ts: t, bpm: core ? 155 : (warm ? 100 : 52)))
            gravity.append(GravitySample(ts: t, x: (warm || core) ? Double(t % 2) * 0.5 : 0, y: 0, z: 1))
        }
        let plain = AnalyticsEngine.detectDayBouts(hr: samples, gravity: gravity, restingHR: 52, maxHR: 185,
                                                   profile: profile)
        let onEfforts = AnalyticsEngine.detectDayBouts(hr: samples, gravity: gravity, restingHR: 52,
                                                       effortRestingHR: 62, maxHR: 185, profile: profile)
        let a = try XCTUnwrap(plain.first), b = try XCTUnwrap(onEfforts.first)
        XCTAssertEqual(plain.count, onEfforts.count)
        XCTAssertEqual(a.start, b.start)
        XCTAssertEqual(a.end, b.end)
        XCTAssertEqual(a.caloriesKcal, b.caloriesKcal, "energy keeps the day's baseline")
        let window = samples.filter { $0.ts >= b.start && $0.ts <= b.end }
        XCTAssertEqual(try XCTUnwrap(b.strain), try XCTUnwrap(StrainScorer.strain(
            window, maxHR: 185, restingHR: 62, lowIntensity: .counted)), accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(b.strain), try XCTUnwrap(a.strain))
        XCTAssertLessThan(try XCTUnwrap(b.avgHRRPct), try XCTUnwrap(a.avgHRRPct))
    }
}
