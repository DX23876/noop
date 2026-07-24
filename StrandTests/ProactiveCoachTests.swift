import XCTest
import WhoopStore
@testable import Strand

/// Pins the P10 proactive detector: the coach reaches out only on a REAL signal in the plan history
/// (a completion streak, a run of skips/declines), never on noise, and honours the user's level dial.
/// Pure — no network, no store singleton. (@MainActor only because the instruction helpers are statics
/// on the @MainActor engine; the detector itself is plain.)
@MainActor
final class ProactiveCoachTests: XCTestCase {

    private func p(day: String, status: PlanProposal.Status,
                   skipReason: PlanProposal.SkipReason? = nil, decidedAt: Date) -> PlanProposal {
        PlanProposal(day: day, sport: "Ride", intent: .easy, status: status,
                     skipReason: skipReason, decidedAt: decidedAt)
    }

    private func daysAgo(_ n: Int, now: Date) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

    // MARK: - Biometric day-row helpers

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// A stable, far-in-the-past day key so the detector's future-day guard never excludes it regardless
    /// of when the test actually runs.
    private func dayKey(_ n: Int) -> String {
        let base = Self.dayFormatter.date(from: "2020-01-01")!
        return Self.dayFormatter.string(from: base.addingTimeInterval(Double(n) * 86_400))
    }

    private func dm(_ n: Int, avgHrv: Double? = nil, restingHr: Int? = nil,
                    recovery: Double? = nil, totalSleepMin: Double? = nil) -> DailyMetric {
        DailyMetric(day: dayKey(n), totalSleepMin: totalSleepMin, efficiency: nil, deepMin: nil,
                   remMin: nil, lightMin: nil, disturbances: nil, restingHr: restingHr, avgHrv: avgHrv,
                   recovery: recovery, strain: nil, exerciseCount: nil)
    }

    /// 14 baseline nights (indices 0..<14) + 5 trailing nights (14..<19), `field` constant within each
    /// window — the shape every `trendSignal` threshold needs to evaluate.
    private func trendDays(baseline: Double, trailing: Double,
                           field: @escaping (Int, Double) -> DailyMetric) -> [DailyMetric] {
        (0..<14).map { field($0, baseline) } + (14..<19).map { field($0, trailing) }
    }

    // MARK: - Nothing fires on an empty or quiet history

    func testNoSignalWhenNothingHasHappened() {
        XCTAssertNil(ProactiveCoach.detect(proposals: [], goals: [], days: [], level: .normal))
    }

    func testOffLevelNeverFires() {
        let now = Date()
        let streak = (0..<6).map { p(day: "2026-07-0\($0+1)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        XCTAssertNil(ProactiveCoach.detect(proposals: streak, goals: [], days: [], level: .off),
                     "off must silence even a genuine milestone")
    }

    // MARK: - Milestone (10.2)

    func testACompletionStreakIsAMilestone() {
        let now = Date()
        let streak = (0..<3).map { p(day: "d\($0)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        let signal = ProactiveCoach.detect(proposals: streak, goals: [], days: [], level: .normal)
        XCTAssertEqual(signal?.category, .milestone)
    }

    func testASmallMilestoneIsSuppressedAtImportantOnly() {
        let now = Date()
        // A 3-streak is a milestone but NOT a big one → hidden at .important, shown at .normal.
        let streak = (0..<3).map { p(day: "d\($0)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        XCTAssertNil(ProactiveCoach.detect(proposals: streak, goals: [], days: [], level: .important))
        XCTAssertEqual(ProactiveCoach.detect(proposals: streak, goals: [], days: [], level: .normal)?.category, .milestone)
    }

    func testABigStreakSurvivesImportantOnly() {
        let now = Date()
        let streak = (0..<5).map { p(day: "d\($0)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        let signal = ProactiveCoach.detect(proposals: streak, goals: [], days: [], level: .important)
        XCTAssertEqual(signal?.category, .milestone)
        XCTAssertTrue(signal?.important ?? false)
    }

    // MARK: - Setback (10.3) and its priority

    func testARunOfSkipsIsASetback() {
        let now = Date()
        let skips = (0..<3).map { p(day: "d\($0)", status: .skipped, skipReason: .noTime, decidedAt: daysAgo($0, now: now)) }
        let signal = ProactiveCoach.detect(proposals: skips, goals: [], days: [], level: .important)
        XCTAssertEqual(signal?.category, .setback, "a setback must reach even the important-only level")
    }

    func testARunOfDeclinesIsASetback() {
        let now = Date()
        let declines = (0..<3).map { p(day: "d\($0)", status: .declined, decidedAt: daysAgo($0, now: now)) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: declines, goals: [], days: [], level: .important)?.category, .setback)
    }

    /// A setback outweighs a milestone — the body telling you something matters more than a pat on the back.
    func testSetbackWinsOverMilestone() {
        let now = Date()
        // A completion streak from a week ago, but three fresh skips this week.
        var proposals = (0..<5).map { p(day: "old\($0)", status: .completed, decidedAt: daysAgo(20 + $0, now: now)) }
        proposals += (0..<3).map { p(day: "new\($0)", status: .skipped, skipReason: .tired, decidedAt: daysAgo($0, now: now)) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: proposals, goals: [], days: [], level: .normal)?.category, .setback)
    }

    // MARK: - Windowing

    func testOldSkipsFallOutOfTheWindow() {
        let now = Date()
        // Three skips, but all older than the 7-day window → no setback.
        let stale = (0..<3).map { p(day: "d\($0)", status: .skipped, skipReason: .noTime, decidedAt: daysAgo(10 + $0, now: now)) }
        XCTAssertNil(ProactiveCoach.detectSetback(proposals: stale, now: now))
    }

    // MARK: - Instruction tone

    func testSetbackInstructionForbidsScolding() {
        let signal = ProactiveSignal(category: .setback, important: true, seed: "3 sessions missed")
        let text = AICoachEngine.proactiveNudgeInstruction(for: signal)
        XCTAssertTrue(text.contains("NEVER laziness"))
        XCTAssertTrue(text.contains("3 sessions missed"), "the factual seed must reach the message")
    }

    func testMilestoneInstructionIsAWarmSingleMessage() {
        let signal = ProactiveSignal(category: .milestone, important: false, seed: "3 in a row")
        let text = AICoachEngine.proactiveNudgeInstruction(for: signal)
        XCTAssertTrue(text.contains("congratulate"))
        XCTAssertTrue(text.contains("3 in a row"))
    }

    // MARK: - Biometric trend (HRV / RHR / recovery / sleep)

    func testHRVDowntrendIsABodyConcern() {
        let now = Date()
        let days = trendDays(baseline: 60, trailing: 45) { self.dm($0, avgHrv: $1) }   // -25%
        let signal = ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .important)
        XCTAssertEqual(signal?.category, .bodyConcern)
        XCTAssertTrue(signal?.important ?? false, "a concerning body signal must reach important-only")
    }

    func testHRVUptrendIsABodyPositiveButNotImportantOnly() {
        let days = trendDays(baseline: 60, trailing: 75) { self.dm($0, avgHrv: $1) }   // +25%
        XCTAssertEqual(ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .normal)?.category, .bodyPositive)
        XCTAssertNil(ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .important),
                     "a positive body signal is a small win, not important-only material")
    }

    func testRestingHRUptrendIsABodyConcern() {
        let days = trendDays(baseline: 50, trailing: 56) { self.dm($0, restingHr: Int($1)) }   // +12%
        XCTAssertEqual(ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .important)?.category, .bodyConcern)
    }

    func testSleepDurationDowntrendIsABodyConcern() {
        // `trendDays` shapes 14 baseline + 5 trailing; the sleep check's shorter 3-night trailing window
        // means its 14-night baseline slice pulls in 2 already-trailing nights (17-back from the end, not
        // 19), so the effective drop is a bit under the nominal 420→340 (~19%) — still comfortably past
        // the 15% threshold either way.
        let days = trendDays(baseline: 420, trailing: 340) { self.dm($0, totalSleepMin: $1) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .normal)?.category, .bodyConcern)
    }

    func testSustainedLowRecoveryIsABodyConcern() {
        let days = (0..<3).map { dm($0, recovery: 25) }
        let signal = ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .important)
        XCTAssertEqual(signal?.category, .bodyConcern)
        XCTAssertTrue(signal?.seed.contains("33") ?? false)
    }

    func testOneRoughRecoveryNightIsNotASignal() {
        let days = [dm(0, recovery: 25), dm(1, recovery: 60), dm(2, recovery: 55)]
        XCTAssertNil(ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .normal))
    }

    func testFlatHRVIsNoSignal() {
        let days = trendDays(baseline: 60, trailing: 60) { self.dm($0, avgHrv: $1) }
        XCTAssertNil(ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .normal))
    }

    func testTooFewNightsIsNoSignal() {
        // Only 5 nights total — never reaches the 14-night baseline + 5-night trailing minimum.
        let days = (0..<5).map { dm($0, avgHrv: 30) }
        XCTAssertNil(ProactiveCoach.detect(proposals: [], goals: [], days: days, level: .normal))
    }

    /// A concerning body signal outranks a plan setback — the body matters more than adherence tracking.
    func testBodyConcernOutranksSetback() {
        let now = Date()
        let skips = (0..<3).map { p(day: "d\($0)", status: .skipped, skipReason: .noTime, decidedAt: daysAgo($0, now: now)) }
        let days = trendDays(baseline: 60, trailing: 45) { self.dm($0, avgHrv: $1) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: skips, goals: [], days: days, level: .normal)?.category, .bodyConcern)
    }

    /// A positive body signal is secondary to a real plan milestone — a quieter kind of good news.
    func testMilestoneOutranksPositiveBodySignal() {
        let now = Date()
        let streak = (0..<5).map { p(day: "d\($0)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        let days = trendDays(baseline: 60, trailing: 75) { self.dm($0, avgHrv: $1) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: streak, goals: [], days: days, level: .normal)?.category, .milestone)
    }

    func testBodyConcernInstructionAvoidsPlanFraming() {
        let signal = ProactiveSignal(category: .bodyConcern, important: true, seed: "HRV down about 25%")
        let text = AICoachEngine.proactiveNudgeInstruction(for: signal)
        XCTAssertTrue(text.contains("NOT a plan"))
        XCTAssertTrue(text.contains("HRV down about 25%"))
    }

    func testBodyPositiveInstructionAvoidsPlanFraming() {
        let signal = ProactiveSignal(category: .bodyPositive, important: false, seed: "HRV up about 20%")
        let text = AICoachEngine.proactiveNudgeInstruction(for: signal)
        XCTAssertTrue(text.contains("not a plan milestone"))
        XCTAssertTrue(text.contains("HRV up about 20%"))
    }

    // MARK: - Goal deadline (forward-looking, the counterpart to expiredGoalNeedingReview)

    private func goal(daysUntilTarget: Int?, kind: CoachGoal.Kind = .custom,
                      title: String = "Half-Marathon", status: CoachGoal.Status = .active,
                      now: Date = Date()) -> CoachGoal {
        CoachGoal(kind: kind, title: title,
                 targetDate: daysUntilTarget.map { daysAgo(-$0, now: now) },
                 status: status)
    }

    /// A deadline 5 days out beats a plan setback — a goal's own target date is always important.
    func testGoalDeadlineWithinAWeekOutranksASetback() {
        let now = Date()
        let goals = [goal(daysUntilTarget: 5, now: now)]
        let skips = (0..<3).map { p(day: "d\($0)", status: .skipped, skipReason: .noTime, decidedAt: daysAgo($0, now: now)) }
        let signal = ProactiveCoach.detect(proposals: skips, goals: goals, days: [], level: .important, now: now)
        XCTAssertEqual(signal?.category, .goalDeadline)
        XCTAssertTrue(signal?.important ?? false)
        XCTAssertEqual(signal?.goalId, goals[0].id)
    }

    /// A deadline 10 days out loses to a setback, and is silent at `.important` (nice-to-know, not urgent)
    /// — mirrors how a small milestone behaves.
    func testGoalDeadlineBeyondAWeekLosesToASetbackAndIsQuietAtImportantOnly() {
        let now = Date()
        let goals = [goal(daysUntilTarget: 10, now: now)]
        let skips = (0..<3).map { p(day: "d\($0)", status: .skipped, skipReason: .noTime, decidedAt: daysAgo($0, now: now)) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: skips, goals: goals, days: [], level: .normal, now: now)?.category,
                       .setback, "a real setback still wins over a distant deadline")

        XCTAssertNil(ProactiveCoach.detect(proposals: [], goals: goals, days: [], level: .important, now: now),
                    "8-14 days out is nice-to-know, not urgent enough for important-only")
        let signal = ProactiveCoach.detect(proposals: [], goals: goals, days: [], level: .normal, now: now)
        XCTAssertEqual(signal?.category, .goalDeadline)
        XCTAssertFalse(signal?.important ?? true)
    }

    /// Expired, paused, and achieved goals have nothing left to look FORWARD to.
    func testClosedOrExpiredGoalsProduceNoDeadlineSignal() {
        let now = Date()
        XCTAssertNil(ProactiveCoach.detectGoalDeadline(goals: [goal(daysUntilTarget: -2, now: now)], now: now),
                    "already past its date — that's expiredGoalNeedingReview's job, not this one's")
        for status: CoachGoal.Status in [.paused, .achieved, .abandoned, .archived] {
            XCTAssertNil(ProactiveCoach.detectGoalDeadline(goals: [goal(daysUntilTarget: 5, status: status, now: now)], now: now),
                        "\(status) goals aren't being actively worked toward")
        }
    }

    /// A goal more than 14 days out is too far ahead to be a "coming up" nudge yet.
    func testGoalDeadlineFartherThanTwoWeeksProducesNoSignal() {
        let now = Date()
        XCTAssertNil(ProactiveCoach.detectGoalDeadline(goals: [goal(daysUntilTarget: 30, now: now)], now: now))
    }

    /// Several qualifying goals → the NEAREST deadline wins, deterministically.
    func testNearestOfSeveralGoalDeadlinesWins() {
        let now = Date()
        let soon = goal(daysUntilTarget: 6, title: "10K Race", now: now)
        let later = goal(daysUntilTarget: 12, title: "Half-Marathon", now: now)
        let signal = ProactiveCoach.detectGoalDeadline(goals: [later, soon], now: now)
        XCTAssertEqual(signal?.goalId, soon.id)
        XCTAssertTrue(signal?.seed.contains("10K Race") ?? false)
    }

    /// The seed folds in the run/strength phase when one applies — context a deadline nudge should carry.
    func testGoalDeadlineSeedIncludesPhaseForARunGoal() {
        let now = Date()
        // 5 days out → weeksRemaining < 1 → "taper" phase.
        let signal = ProactiveCoach.detectGoalDeadline(goals: [goal(daysUntilTarget: 5, kind: .run, now: now)], now: now)
        XCTAssertTrue(signal?.seed.contains("taper") ?? false)
    }

    /// A non-run/strength goal (no `phase()`) still produces a plain seed, without crashing on the nil.
    func testGoalDeadlineSeedOmitsPhaseForANonPhasedGoalKind() {
        let now = Date()
        let signal = ProactiveCoach.detectGoalDeadline(goals: [goal(daysUntilTarget: 5, kind: .sleep, now: now)], now: now)
        XCTAssertNotNil(signal)
        XCTAssertFalse(signal?.seed.contains("phase") ?? true)
    }

    func testGoalDeadlineInstructionNamesTheGoalWithoutPressureOrPrediction() {
        let signal = ProactiveSignal(category: .goalDeadline, important: true,
                                     seed: "Half-Marathon target date is in 5 days (taper phase)")
        let text = AICoachEngine.proactiveNudgeInstruction(for: signal)
        XCTAssertTrue(text.contains("Half-Marathon target date is in 5 days (taper phase)"))
        XCTAssertTrue(text.contains("No success prediction, no"))
        XCTAssertTrue(text.contains("not a test"))
    }
}
