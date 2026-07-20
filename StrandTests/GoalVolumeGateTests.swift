import XCTest
@testable import Strand

/// The combined-volume gate is deliberately coarse (no load-tracking, no fixed weekly-frequency field on
/// a run goal) — these pin its named thresholds/estimates and, above all, that it WARNS and never blocks,
/// the same governing principle `GoalSafetyGate` follows.
@MainActor
final class GoalVolumeGateTests: XCTestCase {

    func testASingleModestGoalIsFine() {
        let consistency = CoachGoal(kind: .consistency, title: "Train regularly", target: 3)
        let a = GoalVolumeGate.assess(draft: consistency, against: [])
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertNil(a.warning)
    }

    /// Run (assumed 3/week) + strength (assumed 2/week) + a high-frequency consistency goal (target 8)
    /// sums past the named threshold (10) — a real, if coarse, combined-load concern.
    func testSeveralActiveGoalsCanCombineIntoAVolumeConcern() {
        let run = CoachGoal(kind: .run, title: "5k")
        let strength = CoachGoal(kind: .strength, title: "Bench 100kg")
        let consistency = CoachGoal(kind: .consistency, title: "Train often", target: 8)

        let a = GoalVolumeGate.assess(draft: consistency, against: [run, strength])
        XCTAssertEqual(a.verdict, .volumeConcern)
        XCTAssertNotNil(a.warning)
        XCTAssertEqual(a.combinedSessionsPerWeek,
                       GoalVolumeGate.assumedRunSessionsPerWeek + GoalVolumeGate.assumedStrengthSessionsPerWeek + 8,
                       accuracy: 0.001)
    }

    /// The gate never blocks — only `warning`/`verdict` change; there is no analogue to
    /// `GoalSafetyGate.requiresReason` here, since there's no acknowledgement to record.
    func testNeverBlocksEvenWellPastTheThreshold() {
        let goals = [
            CoachGoal(kind: .consistency, title: "a", target: 10),
            CoachGoal(kind: .run, title: "b"),
            CoachGoal(kind: .strength, title: "c"),
        ]
        let a = GoalVolumeGate.assess(draft: goals[0], against: Array(goals[1...]))
        XCTAssertEqual(a.verdict, .volumeConcern)
        // No `requiresReason`/blocking property exists on `Assessment` — the type itself has no way to
        // stop a save, which is the point.
    }

    /// Kinds with no combined-volume estimate (sleep/weight/stress/recovery/custom) never contribute,
    /// however many are active — the gate only ever judges run/consistency/strength load.
    func testUnrelatedGoalKindsNeverContributeToTheTotal() {
        let sleep = CoachGoal(kind: .sleep, title: "7.5h")
        let weight = CoachGoal(kind: .weight, title: "78kg", baseline: 80, target: 78)
        let stress = CoachGoal(kind: .stress, title: "calmer")
        let recovery = CoachGoal(kind: .recovery, title: "bounce back")
        let custom = CoachGoal(kind: .custom, title: "feel good")

        let a = GoalVolumeGate.assess(draft: sleep, against: [weight, stress, recovery, custom])
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertEqual(a.combinedSessionsPerWeek, 0)
    }

    /// Editing a goal in place (or replacing one of the same kind) must not double-count it against its
    /// own stale copy in `activeGoals` — `excludingId` is exactly for this.
    func testExcludingIdPreventsDoubleCountingTheGoalBeingEdited() {
        let existing = CoachGoal(kind: .consistency, title: "Train often", target: 9)
        let edited = CoachGoal(id: existing.id, kind: .consistency, title: "Train often", target: 9)

        let withoutExclusion = GoalVolumeGate.assess(draft: edited, against: [existing])
        let withExclusion = GoalVolumeGate.assess(draft: edited, against: [existing], excludingId: existing.id)

        XCTAssertEqual(withoutExclusion.combinedSessionsPerWeek, 18, accuracy: 0.001,
                       "without exclusion the same goal is (incorrectly) counted twice")
        XCTAssertEqual(withExclusion.combinedSessionsPerWeek, 9, accuracy: 0.001,
                       "with exclusion the edited goal is counted exactly once")
    }

    /// A goal that's no longer active/paused (achieved/abandoned/archived) never contributes, even if
    /// passed in `against` by mistake — only live commitments count toward the weekly load.
    func testClosedGoalsDoNotContributeToTheTotal() {
        var closed = CoachGoal(kind: .run, title: "old 5k")
        closed.status = .achieved
        let draft = CoachGoal(kind: .sleep, title: "7.5h")

        let a = GoalVolumeGate.assess(draft: draft, against: [closed])
        XCTAssertEqual(a.combinedSessionsPerWeek, 0)
    }
}
