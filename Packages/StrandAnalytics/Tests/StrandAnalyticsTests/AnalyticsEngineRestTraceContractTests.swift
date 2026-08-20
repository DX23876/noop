import XCTest
@testable import StrandAnalytics

final class AnalyticsEngineRestTraceContractTests: XCTestCase {
    private let day = "2025-06-10"

    private func analyze(stage: String, efficiency: Double) -> (AnalyticsEngine.DayResult, [String]) {
        let start = AnalyticsEngine.dayStartUtcSeconds(day) + 3_600
        let end = start + 1_800
        let provided = SleepSession(
            start: start,
            end: end,
            efficiency: efficiency,
            stages: [StageSegment(start: start, end: end, stage: stage)],
            restingHR: nil,
            avgHRV: nil
        )
        var lines: [String] = []
        let result = AnalyticsEngine.analyzeDay(
            day: day,
            profile: UserProfile(),
            providedSleep: [provided],
            traceSink: { lines.append($0) }
        )
        return (result, lines)
    }

    func testWakeOnlySessionOmitsRestScoreAndRestTrace() {
        let result = analyze(stage: "wake", efficiency: 0.0)
        XCTAssertNil(result.0.restScore)
        XCTAssertEqual(result.1.filter { $0.hasPrefix("rest ") }, [])
        XCTAssertTrue(result.1.contains(
            "sleep-motion day=2025-06-10 grav=0 hr=0 sparse=false stager=V1 family=whoop5"
        ), "non-Rest diagnostics must remain available when Rest is absent")
    }

    func testPositiveSleepKeepsExactRestTrace() {
        let result = analyze(stage: "light", efficiency: 1.0)
        XCTAssertEqual(result.0.restScore, 28.13)
        XCTAssertEqual(result.1.filter { $0.hasPrefix("rest ") }, [
            "rest composite=28.13 dur=0.06*wDur=0.5 eff=1.0*wEff=0.2 "
                + "restor=0.0*wRestor=0.2 deepFactor=0.5 consist=0.5*wConsist=0.1 "
                + "group=1 groupInBedMin=30",
        ])
    }
}
