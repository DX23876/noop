import XCTest
@testable import StrandAnalytics

final class GoalMilestonesTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private func date(_ daysFromNow: Double, from base: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> Date {
        base.addingTimeInterval(daysFromNow * 86_400)
    }
    private var start: Date { Date(timeIntervalSince1970: 1_770_000_000) }

    // MARK: - Waypoints

    /// The headline case: 100 kg → 70 kg lands on the fives a person would pick themselves.
    func testWeightLossLandsOnRoundFives() {
        let m = GoalMilestones.suggest(baseline: 100, target: 70,
                                       createdAt: start, targetDate: date(180))
        XCTAssertEqual(m.map(\.value), [95, 90, 85, 80, 75, 70])
    }

    /// A small span must not produce a thicket of waypoints.
    func testSmallSpanUsesWholeUnits() {
        let m = GoalMilestones.suggest(baseline: 82, target: 78,
                                       createdAt: start, targetDate: date(90))
        XCTAssertEqual(m.map(\.value), [81, 80, 79, 78])
    }

    /// Counting UP reads the same way as counting down — the direction is not a special case.
    func testAscendingGoalIsOrderedTowardTheTarget() {
        let m = GoalMilestones.suggest(baseline: 5, target: 21,
                                       createdAt: start, targetDate: date(120))
        XCTAssertEqual(m.first!.value, 10)
        XCTAssertEqual(m.last!.value, 21, "the target is always the final waypoint")
        XCTAssertEqual(m.map(\.value), m.map(\.value).sorted(), "ascending goal, ascending waypoints")
    }

    /// Whatever the span, the route stays readable and never repeats an endpoint.
    func testCountStaysReasonableAndEndpointsAreNeverRepeated() {
        for (baseline, target) in [(100.0, 70.0), (82.0, 78.0), (5.0, 21.0), (60.0, 60.5), (7.0, 42.0)] {
            let m = GoalMilestones.suggest(baseline: baseline, target: target,
                                           createdAt: start, targetDate: date(180))
            XCTAssertFalse(m.isEmpty, "\(baseline)→\(target)")
            XCTAssertLessThanOrEqual(m.count, 9, "\(baseline)→\(target) produced \(m.count)")
            XCTAssertEqual(m.last?.value, target, "\(baseline)→\(target)")
            XCTAssertFalse(m.dropLast().contains { abs($0.value - baseline) < 1e-9 },
                           "the starting point is not a waypoint")
            XCTAssertEqual(Set(m.map(\.value)).count, m.count, "no duplicates")
        }
    }

    /// Expected dates follow the planned rate: the halfway value falls at halfway time.
    func testExpectedDatesFollowThePlannedRate() {
        let m = GoalMilestones.suggest(baseline: 100, target: 70,
                                       createdAt: start, targetDate: date(180))
        let midpoint = m.first { $0.value == 85 }!
        XCTAssertEqual(midpoint.expectedDate.timeIntervalSince(start) / day, 90, accuracy: 0.5)
        XCTAssertEqual(m.last!.expectedDate.timeIntervalSince(start) / day, 180, accuracy: 0.5)
    }

    func testDegenerateInputsProduceNoRoute() {
        XCTAssertTrue(GoalMilestones.suggest(baseline: 80, target: 80,
                                             createdAt: start, targetDate: date(90)).isEmpty)
        XCTAssertTrue(GoalMilestones.suggest(baseline: 100, target: 70,
                                             createdAt: start, targetDate: start).isEmpty,
                      "a runway with no length has no schedule")
    }

    // MARK: - Course

    /// A steady series from a known slope must be recovered as that slope.
    private func series(from: Double, perDay: Double, days: Int, endingAt end: Date) -> [GoalMilestones.Sample] {
        (0..<days).map { i in
            let d = end.addingTimeInterval(-Double(days - 1 - i) * 86_400)
            return .init(date: d, value: from + perDay * Double(i))
        }
    }

    /// The user's own example, pinned: 100 → 70 over six months, currently 92.4 where the plan says
    /// 91.5, losing ~0.16 kg/day. Behind, and arriving late.
    func testBehindPlanProjectsALaterArrival() {
        let now = date(60)
        let s = series(from: 97.0, perDay: -0.153, days: 30, endingAt: now)
        let c = GoalMilestones.course(baseline: 100, target: 70, createdAt: start,
                                      targetDate: date(180), current: 92.4, series: s, now: now)!
        XCTAssertEqual(c.plannedNow, 90.0, accuracy: 0.1)
        XCTAssertEqual(c.deviation, 2.4, accuracy: 0.1, "heavier than planned reads positive")
        XCTAssertEqual(c.verdict, .behind)
        XCTAssertNotNil(c.projectedDate)
        XCTAssertGreaterThan(c.daysLate!, 0, "at this rate the target arrives after the target date")
    }

    /// Moving the wrong way must NOT produce a date. The formula would happily return one in the past.
    func testMovingAwayNeverProducesAnArrivalDate() {
        let now = date(60)
        let s = series(from: 92.0, perDay: +0.05, days: 30, endingAt: now)   // gaining, goal is to lose
        let c = GoalMilestones.course(baseline: 100, target: 70, createdAt: start,
                                      targetDate: date(180), current: 93.5, series: s, now: now)!
        XCTAssertEqual(c.verdict, .movingAway)
        XCTAssertNil(c.projectedDate)
        XCTAssertNil(c.daysLate)
    }

    /// A crawl toward the target is honest about being unforeseeable rather than printing a date
    /// decades out.
    func testAGlacialRateIsUnforeseeable() {
        let now = date(60)
        let s = series(from: 99.6, perDay: -0.002, days: 30, endingAt: now)
        let c = GoalMilestones.course(baseline: 100, target: 70, createdAt: start,
                                      targetDate: date(180), current: 99.5, series: s, now: now)!
        XCTAssertEqual(c.verdict, .unforeseeable)
        XCTAssertNil(c.projectedDate)
    }

    /// Too little history says so instead of fitting a line through noise.
    func testTooLittleHistoryIsNotEnoughData() {
        let now = date(60)
        let s = series(from: 95.0, perDay: -0.1, days: 5, endingAt: now)
        let c = GoalMilestones.course(baseline: 100, target: 70, createdAt: start,
                                      targetDate: date(180), current: 94.5, series: s, now: now)!
        XCTAssertEqual(c.verdict, .notEnoughData)
        XCTAssertNil(c.observedRatePerDay)
        XCTAssertNil(c.projectedDate)
        XCTAssertEqual(c.plannedNow, 90.0, accuracy: 0.1, "the planned line needs no measurements")
    }

    /// Sitting on the planned line reads as on course, not as a rounding-error verdict.
    func testOnTheLineReadsAsOnCourse() {
        let now = date(60)
        let s = series(from: 95.0, perDay: -0.166, days: 30, endingAt: now)
        let c = GoalMilestones.course(baseline: 100, target: 70, createdAt: start,
                                      targetDate: date(180), current: 90.0, series: s, now: now)!
        XCTAssertEqual(c.verdict, .onCourse)
    }

    func testRateFitRecoversAKnownSlope() {
        let now = date(60)
        let s = series(from: 95.0, perDay: -0.2, days: 30, endingAt: now)
        XCTAssertEqual(GoalMilestones.observedRatePerDay(series: s, now: now)!, -0.2, accuracy: 0.001)
    }
}
