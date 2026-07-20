import XCTest
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

    // MARK: - Nothing fires on an empty or quiet history

    func testNoSignalWhenNothingHasHappened() {
        XCTAssertNil(ProactiveCoach.detect(proposals: [], goals: [], level: .normal))
    }

    func testOffLevelNeverFires() {
        let now = Date()
        let streak = (0..<6).map { p(day: "2026-07-0\($0+1)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        XCTAssertNil(ProactiveCoach.detect(proposals: streak, goals: [], level: .off),
                     "off must silence even a genuine milestone")
    }

    // MARK: - Milestone (10.2)

    func testACompletionStreakIsAMilestone() {
        let now = Date()
        let streak = (0..<3).map { p(day: "d\($0)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        let signal = ProactiveCoach.detect(proposals: streak, goals: [], level: .normal)
        XCTAssertEqual(signal?.category, .milestone)
    }

    func testASmallMilestoneIsSuppressedAtImportantOnly() {
        let now = Date()
        // A 3-streak is a milestone but NOT a big one → hidden at .important, shown at .normal.
        let streak = (0..<3).map { p(day: "d\($0)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        XCTAssertNil(ProactiveCoach.detect(proposals: streak, goals: [], level: .important))
        XCTAssertEqual(ProactiveCoach.detect(proposals: streak, goals: [], level: .normal)?.category, .milestone)
    }

    func testABigStreakSurvivesImportantOnly() {
        let now = Date()
        let streak = (0..<5).map { p(day: "d\($0)", status: .completed, decidedAt: daysAgo($0, now: now)) }
        let signal = ProactiveCoach.detect(proposals: streak, goals: [], level: .important)
        XCTAssertEqual(signal?.category, .milestone)
        XCTAssertTrue(signal?.important ?? false)
    }

    // MARK: - Setback (10.3) and its priority

    func testARunOfSkipsIsASetback() {
        let now = Date()
        let skips = (0..<3).map { p(day: "d\($0)", status: .skipped, skipReason: .noTime, decidedAt: daysAgo($0, now: now)) }
        let signal = ProactiveCoach.detect(proposals: skips, goals: [], level: .important)
        XCTAssertEqual(signal?.category, .setback, "a setback must reach even the important-only level")
    }

    func testARunOfDeclinesIsASetback() {
        let now = Date()
        let declines = (0..<3).map { p(day: "d\($0)", status: .declined, decidedAt: daysAgo($0, now: now)) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: declines, goals: [], level: .important)?.category, .setback)
    }

    /// A setback outweighs a milestone — the body telling you something matters more than a pat on the back.
    func testSetbackWinsOverMilestone() {
        let now = Date()
        // A completion streak from a week ago, but three fresh skips this week.
        var proposals = (0..<5).map { p(day: "old\($0)", status: .completed, decidedAt: daysAgo(20 + $0, now: now)) }
        proposals += (0..<3).map { p(day: "new\($0)", status: .skipped, skipReason: .tired, decidedAt: daysAgo($0, now: now)) }
        XCTAssertEqual(ProactiveCoach.detect(proposals: proposals, goals: [], level: .normal)?.category, .setback)
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
}
