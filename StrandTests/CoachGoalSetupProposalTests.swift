import XCTest
@testable import Strand

@MainActor
final class CoachGoalSetupProposalTests: XCTestCase {
    private func stores(_ name: String = #function) -> (
        String, UserDefaults, CoachGoalSetupProposalStore, CoachGoalStore, GoalActionStore
    ) {
        let suite = "CoachGoalSetup-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (suite, defaults,
                CoachGoalSetupProposalStore(defaults: defaults, storageKey: "setups"),
                CoachGoalStore(defaults: defaults),
                GoalActionStore(defaults: defaults, storageKey: "actions"))
    }

    private func proposal(goal: CoachGoal? = nil,
                          routines: [CoachGoalSetupProposal.RoutineDraft] = [])
        -> CoachGoalSetupProposal {
        let goalDraft = goal.map {
            CoachGoalSetupProposal.GoalDraft(operation: .create, editingId: nil,
                                             goal: $0, baselineEvidence: nil)
        }
        return CoachGoalSetupProposal(goal: goalDraft, routines: routines,
                                      rationale: "A small repeatable setup")
    }

    func testProposalIsPersistentButInertUntilAccepted() {
        let (suite, defaults, proposals, goals, actions) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let goal = CoachGoal(kind: .consistency, title: "Move more")
        let action = GoalAction(title: "Daily walk", requirement: .steps(minimum: 8_000),
                                goalIds: [goal.id])
        let routine = CoachGoalSetupProposal.RoutineDraft(operation: .create, editingId: nil,
                                                          action: action)

        XCTAssertTrue(proposals.propose(proposal(goal: goal, routines: [routine])))
        XCTAssertTrue(goals.goals.isEmpty)
        XCTAssertTrue(actions.actions.isEmpty)
        XCTAssertEqual(proposals.pending.count, 1)

        let reloaded = CoachGoalSetupProposalStore(defaults: defaults, storageKey: "setups")
        XCTAssertEqual(reloaded.pending.first?.goal?.goal.title, "Move more")
        XCTAssertEqual(reloaded.pending.first?.routines.first?.action.goalIds, [goal.id])
    }

    func testProposeCannotPreAcceptItsOwnSetup() {
        let (suite, defaults, proposals, goals, actions) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let goal = CoachGoal(kind: .custom, title: "Keep moving")
        let decided = CoachGoalSetupProposal(goal: .init(operation: .create, editingId: nil,
                                                          goal: goal, baselineEvidence: nil),
                                             routines: [], rationale: "",
                                             status: .accepted, decidedAt: Date())

        proposals.propose(decided)

        XCTAssertEqual(proposals.proposals.first?.status, .proposed)
        XCTAssertNil(proposals.proposals.first?.decidedAt)
        XCTAssertTrue(goals.goals.isEmpty)
        XCTAssertTrue(actions.actions.isEmpty)
    }

    func testApplyCanConfirmGoalAndOnlySelectedRoutines() {
        let (suite, defaults, proposals, goals, actions) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let goal = CoachGoal(kind: .weight, title: "Feel lighter", baseline: 82, target: 76)
        let walk = GoalAction(title: "Walk", requirement: .steps(minimum: 10_000), goalIds: [goal.id])
        let strength = GoalAction(title: "Strength", requirement: .workout(
            sports: ["Strength"], minimumMinutes: 30), schedule: .weekdays([3, 6]), goalIds: [goal.id])
        let drafts = [walk, strength].map {
            CoachGoalSetupProposal.RoutineDraft(operation: .create, editingId: nil, action: $0)
        }
        let value = proposal(goal: goal, routines: drafts)
        proposals.propose(value)

        let selection = CoachGoalSetupApplier.Selection(
            goal: value.goal, includeGoal: true, routines: drafts,
            selectedRoutineIds: [walk.id], replacingGoalId: nil,
            acknowledgedRisk: nil, clearStaleAcknowledgement: false)
        let error = CoachGoalSetupApplier.apply(
            proposalId: value.id, selection: selection, proposalStore: proposals,
            goalStore: goals, actionStore: actions)

        XCTAssertNil(error)
        XCTAssertEqual(goals.activeGoals.map(\.id), [goal.id])
        XCTAssertEqual(actions.actions.map(\.id), [walk.id])
        XCTAssertEqual(actions.actions.first?.goalIds, [goal.id])
        XCTAssertEqual(proposals.proposal(id: value.id)?.status, .accepted)
    }

    func testStaleRoutineUpdateRejectsWholeSelectionBeforeMutation() {
        let (suite, defaults, proposals, goals, actions) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let active = CoachGoal(kind: .custom, title: "Steady days")
        goals.commit(active)
        let missingId = UUID()
        let action = GoalAction(id: missingId, title: "Check in", requirement: .manual,
                                goalIds: [active.id])
        let draft = CoachGoalSetupProposal.RoutineDraft(operation: .update,
                                                        editingId: missingId, action: action)
        let value = proposal(routines: [draft])
        proposals.propose(value)
        let beforeGoals = goals.goals

        let error = CoachGoalSetupApplier.apply(
            proposalId: value.id,
            selection: .init(goal: nil, includeGoal: false, routines: [draft],
                             selectedRoutineIds: [missingId], replacingGoalId: nil,
                             acknowledgedRisk: nil, clearStaleAcknowledgement: false),
            proposalStore: proposals, goalStore: goals, actionStore: actions)

        XCTAssertEqual(error, .routineUnavailable)
        XCTAssertEqual(goals.goals, beforeGoals)
        XCTAssertTrue(actions.actions.isEmpty)
        XCTAssertEqual(proposals.proposal(id: value.id)?.status, .proposed)
    }

    func testCoachToolCreatesReviewDraftWithoutChangingGoalOrActionStores() async {
        let (suite, defaults, proposals, _, _) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AICoachEngine(repo: Repository(deviceId: "test-goal-setup-\(UUID().uuidString)"))
        let goalCount = CoachGoalStore.shared.goals.count
        let actionCount = GoalActionStore.shared.actions.count
        let input: [String: Any] = [
            "goal": ["operation": "create", "kind": "consistency", "title": "Move more"],
            "routines": [[
                "operation": "create", "title": "10,000 steps", "type": "steps",
                "minimum_steps": 10_000, "schedule": "daily", "supports_setup_goal": true,
            ]],
            "rationale": "Walking supports consistency and wellbeing",
        ]

        let result = await engine.proposeGoalSetupTool(input: input, proposalStore: proposals)

        XCTAssertTrue(result.contains("NOT active"))
        XCTAssertEqual(proposals.pending.count, 1)
        XCTAssertEqual(proposals.pending.first?.routines.first?.action.goalIds,
                       [proposals.pending.first!.goal!.goal.id])
        XCTAssertEqual(CoachGoalStore.shared.goals.count, goalCount)
        XCTAssertEqual(GoalActionStore.shared.actions.count, actionCount)
    }

    func testCoachToolRejectsOutOfScopeRoutine() async {
        let (suite, defaults, proposals, _, _) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AICoachEngine(repo: Repository(deviceId: "test-goal-scope-\(UUID().uuidString)"))
        let result = await engine.proposeGoalSetupTool(input: [
            "goal": ["kind": "weight", "title": "Lose weight"],
            "routines": [["title": "Medication dosage", "type": "manual",
                           "supports_setup_goal": true]],
        ], proposalStore: proposals)

        XCTAssertTrue(result.contains("outside Coach scope"))
        XCTAssertTrue(proposals.proposals.isEmpty)
    }
}
