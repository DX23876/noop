import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The daily resting HR is the lowest 5-min bin of the PRIMARY (longest) session. The primary-session
/// selection is #2358's nap fix; the definition stays the nadir rather than #2358's whole-session mean,
/// which this fork records only as the `rhr_primary_session` shadow metric (docs/fork/decisions.md,
/// 2026-09-28). Sessions are handed in through `providedSleep` without a resting HR of their own, so the
/// engine derives each session's nadir itself.
final class AnalyticsEnginePrimaryRestingHRTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2026-07-27"

    /// HR every 30 s over `[start, end)` at `bpm`, except `[dipStart, dipEnd)` at `dipBpm`.
    private func hr(_ start: Int, _ end: Int, bpm: Int,
                    dip: (start: Int, end: Int, bpm: Int)? = nil) -> [HRSample] {
        stride(from: start, to: end, by: 30).map { ts in
            if let dip, ts >= dip.start, ts < dip.end { return HRSample(ts: ts, bpm: dip.bpm) }
            return HRSample(ts: ts, bpm: bpm)
        }
    }

    private func session(_ start: Int, _ end: Int) -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 0.9,
                     stages: [StageSegment(start: start, end: end, stage: "light")],
                     restingHR: nil, avgHRV: nil)
    }

    /// Main night 20:00–04:00 at 60 bpm with one 10-min stretch at 50 (bin-aligned), then a 40-min
    /// nap 05:00–05:40 at 44 bpm. Both end on `day`.
    private func nightAndNap() -> (night: SleepSession, nap: SleepSession, hr: [HRSample]) {
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let nightStart = dayStart - 4 * 3600
        let nightEnd = nightStart + 8 * 3600
        let dipStart = nightStart + 300 * 60
        let napStart = dayStart + 5 * 3600
        let napEnd = napStart + 40 * 60
        let samples = hr(nightStart, nightEnd, bpm: 60, dip: (dipStart, dipStart + 10 * 60, 50))
            + hr(napStart, napEnd, bpm: 44)
        return (session(nightStart, nightEnd), session(napStart, napEnd), samples)
    }

    func testDailyRestingHRIsThePrimarySessionsNadirNotTheNapNorTheMean() {
        let (night, nap, samples) = nightAndNap()
        let res = AnalyticsEngine.analyzeDay(day: day, hr: samples, rr: [], profile: profile,
                                             providedSleep: [nap, night])
        XCTAssertEqual(res.daily.restingHr, 50, "the main night's lowest 5-min bin")
        XCTAssertNotEqual(res.daily.restingHr, 44, "a shorter nap must not set the day's resting HR")
    }

    func testDailyRestingHRSitsBelowTheShadowMean() throws {
        let (night, nap, samples) = nightAndNap()
        let res = AnalyticsEngine.analyzeDay(day: day, hr: samples, rr: [], profile: profile,
                                             providedSleep: [night, nap])
        let mean = try XCTUnwrap(AnalyticsEngine.primarySessionRestingHR(sessions: [night, nap], hr: samples))
        XCTAssertEqual(mean, 59.8, accuracy: 0.1, "the shadow metric is still the whole-session mean")
        let rhr = try XCTUnwrap(res.daily.restingHr)
        XCTAssertLessThan(Double(rhr), mean - 5, "the shipped value is the nadir, not the mean")
    }

    /// Upstream #2522, adopted in the 2026-10-01 sync (recipe AI-17): a nap never supplies the daily
    /// resting HR, not even when the main night carries none. The day reads as having no resting HR.
    func testANapDoesNotStandInWhenThePrimaryHasNoNadir() {
        let (night, nap, _) = nightAndNap()
        // No HR inside the main night at all, so it carries no resting HR; the nap's is the only one.
        let napOnly = hr(nap.start, nap.end, bpm: 44)
        let res = AnalyticsEngine.analyzeDay(day: day, hr: napOnly, rr: [], profile: profile,
                                             providedSleep: [night, nap])
        XCTAssertNil(res.daily.restingHr)
    }
}
