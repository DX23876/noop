import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// #2522: the daily RHR takes the primary night's five-minute floor, while the #2358 nap
/// selection and #804 provided-value precedence remain intact. Kotlin has the same fixtures.
final class PrimaryNightRestingHRDailyTests: XCTestCase {
    private let day = "2026-07-27"
    private var nightStart: Int { AnalyticsEngine.dayStartUtcSeconds(day) - 4 * 3600 }
    private var napStart: Int { AnalyticsEngine.dayStartUtcSeconds(day) + 13 * 3600 }
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    private func sessions(primaryRHR: Int? = nil) -> [SleepSession] {
        let nightEnd = nightStart + 600 * 60
        let napEnd = napStart + 40 * 60
        return [
            SleepSession(start: nightStart, end: nightEnd, efficiency: 0.9,
                         stages: [StageSegment(start: nightStart, end: nightEnd, stage: "light")],
                         restingHR: primaryRHR, avgHRV: nil),
            SleepSession(start: napStart, end: napEnd, efficiency: 0.9,
                         stages: [StageSegment(start: napStart, end: napEnd, stage: "light")],
                         restingHR: nil, avgHRV: nil),
        ]
    }

    private func heartRate(includeNight: Bool = true) -> [HRSample] {
        let night = includeNight ? (0..<1200).map { i in
            HRSample(ts: nightStart + i * 30, bpm: i < 10 ? 55 : 70)
        } : []
        let nap = (0..<80).map { i in HRSample(ts: napStart + i * 30, bpm: 45) }
        return night + nap
    }

    func testMainNightFloorWinsOverItsMeanAndALowerNap() {
        let hr = heartRate()
        XCTAssertEqual(SleepStager.sessionRestingHR(start: nightStart, end: nightStart + 600 * 60, hr: hr), 55)
        XCTAssertGreaterThan(AnalyticsEngine.primarySessionRestingHR(sessions: sessions(), hr: hr) ?? 0, 69)
        let result = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: [], profile: profile,
                                                providedSleep: sessions())
        XCTAssertEqual(result.daily.restingHr, 55)
    }

    func testProvidedPrimaryValueStillWins() {
        let result = AnalyticsEngine.analyzeDay(day: day, hr: heartRate(), rr: [], profile: profile,
                                                providedSleep: sessions(primaryRHR: 62))
        XCTAssertEqual(result.daily.restingHr, 62)
    }

    func testNapDoesNotFillAnUnmeasuredPrimaryNight() {
        let result = AnalyticsEngine.analyzeDay(day: day, hr: heartRate(includeNight: false), rr: [],
                                                profile: profile, providedSleep: sessions())
        XCTAssertNil(result.daily.restingHr)
    }
}
