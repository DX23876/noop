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

    // MARK: - Weekly and monthly goals (goals plan §14)

    func testApplyCommitsOnlySelectedPeriodGoalsAndKeepsTheRestInert() {
        let (suite, defaults, proposals, goals, actions) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let periods = PeriodGoalStore(defaults: defaults)
        let workouts = PeriodGoal(metric: .workouts, period: .week, target: 4)
        let sleep = PeriodGoal(metric: .sleepNights, period: .week, target: 5, threshold: 7)
        let value = CoachGoalSetupProposal(goal: nil, routines: [], periodGoals: [workouts, sleep],
                                           rationale: "Two anchors for the week")
        XCTAssertTrue(proposals.propose(value))
        XCTAssertTrue(periods.goals.isEmpty, "a draft never touches the period store")

        let error = CoachGoalSetupApplier.apply(
            proposalId: value.id,
            selection: .init(goal: nil, includeGoal: false, routines: [], selectedRoutineIds: [],
                             replacingGoalId: nil, acknowledgedRisk: nil, clearStaleAcknowledgement: false,
                             periodGoals: [workouts, sleep], selectedPeriodGoalIds: [sleep.id]),
            proposalStore: proposals, goalStore: goals, actionStore: actions,
            periodStore: periods, today: "2026-10-05")

        XCTAssertNil(error)
        XCTAssertEqual(periods.goals.map(\.id), [sleep.id])
        XCTAssertEqual(periods.goals.first?.targetHistory.first?.fromDay, "2026-10-05")
        XCTAssertEqual(proposals.proposal(id: value.id)?.status, .accepted)
    }

    func testApplyRejectsAPeriodGoalAlreadyTrackedBeforeAnyMutation() {
        let (suite, defaults, proposals, goals, actions) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let periods = PeriodGoalStore(defaults: defaults)
        periods.commit(PeriodGoal(metric: .workouts, period: .week, target: 3), today: "2026-10-01")
        let longTerm = CoachGoal(kind: .consistency, title: "Train steadily")
        let duplicate = PeriodGoal(metric: .workouts, period: .week, target: 5)
        let value = CoachGoalSetupProposal(goal: .init(operation: .create, editingId: nil, goal: longTerm,
                                                       baselineEvidence: nil),
                                           routines: [], periodGoals: [duplicate], rationale: "")
        proposals.propose(value)

        let error = CoachGoalSetupApplier.apply(
            proposalId: value.id,
            selection: .init(goal: value.goal, includeGoal: true, routines: [], selectedRoutineIds: [],
                             replacingGoalId: nil, acknowledgedRisk: nil, clearStaleAcknowledgement: false,
                             periodGoals: [duplicate], selectedPeriodGoalIds: [duplicate.id]),
            proposalStore: proposals, goalStore: goals, actionStore: actions, periodStore: periods)

        XCTAssertEqual(error, .periodGoalDuplicate)
        XCTAssertTrue(goals.goals.isEmpty, "the long-term goal in the same draft is not half-applied")
        XCTAssertEqual(periods.goals.count, 1)
        XCTAssertEqual(proposals.proposal(id: value.id)?.status, .proposed)
    }

    func testApplyDropsALinkToTheSetupGoalWhenThatGoalIsLeftOut() {
        let (suite, defaults, proposals, goals, actions) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let periods = PeriodGoalStore(defaults: defaults)
        let longTerm = CoachGoal(kind: .consistency, title: "Train steadily")
        let weekly = PeriodGoal(metric: .workouts, period: .week, target: 3, parentGoalId: longTerm.id)
        let value = CoachGoalSetupProposal(goal: .init(operation: .create, editingId: nil, goal: longTerm,
                                                       baselineEvidence: nil),
                                           routines: [], periodGoals: [weekly], rationale: "")
        proposals.propose(value)

        let error = CoachGoalSetupApplier.apply(
            proposalId: value.id,
            selection: .init(goal: value.goal, includeGoal: false, routines: [], selectedRoutineIds: [],
                             replacingGoalId: nil, acknowledgedRisk: nil, clearStaleAcknowledgement: false,
                             periodGoals: [weekly], selectedPeriodGoalIds: [weekly.id]),
            proposalStore: proposals, goalStore: goals, actionStore: actions, periodStore: periods)

        XCTAssertNil(error)
        XCTAssertNil(periods.goals.first?.parentGoalId)
        XCTAssertTrue(goals.goals.isEmpty)
    }

    func testDraftStoredBeforePeriodGoalsStillDecodes() throws {
        let (suite, defaults, proposals, _, _) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let action = GoalAction(title: "Walk", requirement: .steps(minimum: 8_000), goalIds: [UUID()])
        proposals.propose(CoachGoalSetupProposal(
            goal: nil, routines: [.init(operation: .create, editingId: nil, action: action)], rationale: ""))
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(defaults.data(forKey: "setups"))) as? [[String: Any]])
        stored[0].removeValue(forKey: "periodGoals")
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: "setups")

        let reloaded = CoachGoalSetupProposalStore(defaults: defaults, storageKey: "setups")
        XCTAssertEqual(reloaded.pending.count, 1)
        XCTAssertTrue(reloaded.pending[0].draftedPeriodGoals.isEmpty)
    }

    func testCoachToolDraftsPeriodGoalsOnTheSetupScreensSteps() async {
        let (suite, defaults, proposals, _, _) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AICoachEngine(repo: Repository(deviceId: "test-goal-period-\(UUID().uuidString)"))
        let periodCount = PeriodGoalStore.shared.goals.count

        let result = await engine.proposeGoalSetupTool(input: [
            "period_goals": [
                ["metric": "workouts", "period": "week", "target": 3.6],
                ["metric": "trainingMinutes", "period": "month", "target": 610],
                ["metric": "stepDays", "period": "week", "target": 5],
            ],
            "rationale": "Built from the last four weeks",
        ], proposalStore: proposals)

        XCTAssertTrue(result.contains("NOT active"), result)
        let drafted = proposals.pending.first?.draftedPeriodGoals ?? []
        XCTAssertEqual(drafted.map(\.target), [4, 600, 5])
        XCTAssertEqual(drafted.map(\.period), [.week, .month, .week])
        XCTAssertEqual(drafted[2].threshold, 8_000, "a step-day goal without a threshold gets the usual 8,000")
        XCTAssertEqual(PeriodGoalStore.shared.goals.count, periodCount)
    }

    func testCoachToolRejectsHabitDaysAndImplausibleTargets() async {
        let (suite, defaults, proposals, _, _) = stores()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AICoachEngine(repo: Repository(deviceId: "test-goal-period-bad-\(UUID().uuidString)"))

        let habit = await engine.proposeGoalSetupTool(input: [
            "period_goals": [["metric": "habitDays", "period": "week", "target": 5]],
        ], proposalStore: proposals)
        let tooMany = await engine.proposeGoalSetupTool(input: [
            "period_goals": [["metric": "sleepNights", "period": "week", "target": 9]],
        ], proposalStore: proposals)

        XCTAssertTrue(habit.hasPrefix("Nothing drafted"), habit)
        XCTAssertTrue(tooMany.hasPrefix("Nothing drafted"), tooMany)
        XCTAssertTrue(proposals.proposals.isEmpty)
    }
}
