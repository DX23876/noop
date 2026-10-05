import XCTest
@testable import Strand

/// The long-term goal's catalog fields (template, measure), several goals of one kind, and the one-time
/// template assignment for goals made before the catalog.
@MainActor
final class GoalCatalogModelTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "GoalCatalogModel-\(name)-\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - Storage

    func testTemplateAndMeasureRoundTrip() {
        let d = defaults()
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let spec = GoalMeasureSpec(metric: .distanceTotal, sportFilter: ["Running"], countFrom: start)
        CoachGoalStore(defaults: d).goals = [CoachGoal(kind: .endurance, title: "1.000 km", baseline: 0,
                                                       target: 1_000, templateId: GoalTemplateID.distanceTotal.rawValue,
                                                       measure: spec)]

        let reloaded = CoachGoalStore(defaults: d).goals.first
        XCTAssertEqual(reloaded?.kind, .endurance)
        XCTAssertEqual(reloaded?.templateId, "endurance.distanceTotal")
        XCTAssertEqual(reloaded?.measure, spec)
        XCTAssertEqual(reloaded?.measure?.shape, .sum)
        XCTAssertTrue(reloaded?.unknownFields.isEmpty ?? false)
    }

    /// A measure written by a later build with a metric this one does not know: the goal still loads
    /// and the measure goes back out as it came.
    func testUnknownMetricKeepsTheMeasureVerbatim() throws {
        let d = defaults()
        let json = """
        [{"kind":"fitness","title":"Grip","status":"active","templateId":"fitness.grip",
          "measure":{"metric":"gripStrength","sportFilter":[],"hand":"left"}}]
        """
        d.set(Data(json.utf8), forKey: CoachGoalStore.goalsKey)
        let store = CoachGoalStore(defaults: d)
        XCTAssertEqual(store.goals.count, 1)
        XCTAssertNil(store.goals[0].measure)
        XCTAssertEqual(store.goals[0].templateId, "fitness.grip")

        store.note(store.goals[0].id, "Saved by this build")
        let saved = try XCTUnwrap(d.data(forKey: CoachGoalStore.goalsKey))
        let goal = try XCTUnwrap((try JSONSerialization.jsonObject(with: saved) as? [[String: Any]])?.first)
        let measure = try XCTUnwrap(goal["measure"] as? [String: Any])
        XCTAssertEqual(measure["metric"] as? String, "gripStrength")
        XCTAssertEqual(measure["hand"] as? String, "left")
    }

    /// The editors that predate the catalog build drafts without a template; an edit there keeps it,
    /// unless the edit changes the kind.
    func testLegacyEditKeepsTheTemplateUnlessTheKindChanges() {
        let store = CoachGoalStore(defaults: defaults())
        let goal = CoachGoal(kind: .weight, title: "Lighter", baseline: 90, target: 80,
                             templateId: GoalTemplateID.weightLose.rawValue, measure: .init(metric: .weight))
        store.goals = [goal]

        store.commit(CoachGoal(kind: .weight, title: "Lighter still", baseline: 90, target: 78), editingId: goal.id)
        XCTAssertEqual(store.goal(id: goal.id)?.templateId, "body.weightLose")
        XCTAssertEqual(store.goal(id: goal.id)?.measure, .init(metric: .weight))

        store.commit(CoachGoal(kind: .custom, title: "Something else"), editingId: goal.id)
        XCTAssertNil(store.goal(id: goal.id)?.templateId)
        XCTAssertNil(store.goal(id: goal.id)?.measure)
    }

    func testMaintainIsTheTargetShapeWithABand() {
        XCTAssertEqual(GoalMeasureSpec(metric: .weight).shape, .target)
        XCTAssertEqual(GoalMeasureSpec(metric: .weight, band: 1).shape, .maintain)
        XCTAssertEqual(GoalMeasureSpec(metric: .weeklyAdherence).shape, .consistency)
        XCTAssertEqual(GoalMeasureSpec(metric: .longestDistance).shape, .best)
        XCTAssertEqual(GoalMeasureSpec(metric: .sleepAverage).shape, .average)
    }

    func testEveryTemplateHasAKindAndAMetric() {
        for template in GoalTemplateID.allCases {
            XCTAssertFalse(template.rawValue.isEmpty)
            XCTAssertEqual(GoalTemplateID(rawValue: template.rawValue), template)
            _ = template.kind
            _ = template.metric
        }
        XCTAssertEqual(GoalTemplateID.weightLose.kind, .weight, "weight templates stay under the safety gate")
        XCTAssertEqual(GoalTemplateID.bodyFat.kind, .body)
    }

    func testCatalogAreasAreNotOfferedWithoutATemplate() {
        let free = CoachGoal.Kind.templateFreeCases
        XCTAssertFalse(free.contains(.endurance))
        XCTAssertFalse(free.contains(.habit))
        XCTAssertTrue(free.contains(.weight))
        XCTAssertTrue(free.contains(.custom))
    }

    // MARK: - Several goals of one kind

    func testSameKindIsAnOfferWhileThereIsRoom() {
        let store = CoachGoalStore(defaults: defaults())
        let run = CoachGoal(kind: .run, title: "10 km")
        store.goals = [run]
        XCTAssertEqual(store.canAdd(kind: .run), .kindAlreadyActive(existingId: run.id))
        XCTAssertTrue(store.hasRoom())

        store.goals = (0..<CoachGoalStore.maxActiveGoals).map { CoachGoal(kind: .run, title: "\($0)") }
        XCTAssertFalse(store.hasRoom())
        XCTAssertTrue(store.hasRoom(replacing: store.goals[0].id))
    }

    /// Accepting a coach draft of a kind already active, without choosing to replace: both stay.
    func testCoachDraftCanKeepBothGoals() {
        let suite = "GoalCatalogModel-keepBoth-\(UUID().uuidString)"
        suites.append(suite)
        let d = UserDefaults(suiteName: suite)!
        let proposals = CoachGoalSetupProposalStore(defaults: d, storageKey: "setups")
        let goals = CoachGoalStore(defaults: d)
        let actions = GoalActionStore(defaults: d, storageKey: "actions")
        let first = CoachGoal(kind: .run, title: "10 km")
        goals.goals = [first]
        let second = CoachGoal(kind: .run, title: "Half marathon")
        let draft = CoachGoalSetupProposal.GoalDraft(operation: .create, editingId: nil, goal: second,
                                                     baselineEvidence: nil)
        let value = CoachGoalSetupProposal(goal: draft, routines: [], rationale: "")
        proposals.propose(value)

        let error = CoachGoalSetupApplier.apply(
            proposalId: value.id,
            selection: .init(goal: draft, includeGoal: true, routines: [], selectedRoutineIds: [],
                             replacingGoalId: nil, acknowledgedRisk: nil, clearStaleAcknowledgement: false),
            proposalStore: proposals, goalStore: goals, actionStore: actions)

        XCTAssertNil(error)
        XCTAssertEqual(Set(goals.activeGoals.map(\.id)), [first.id, second.id])
    }

    // MARK: - Conflicts

    func testOppositeWeightGoalsAreNoted() {
        let lose = CoachGoal(kind: .weight, title: "Lose", baseline: 90, target: 80,
                             createdAt: Date(timeIntervalSince1970: 1_000))
        let gain = CoachGoal(kind: .weight, title: "Gain", baseline: 90, target: 95,
                             createdAt: Date(timeIntervalSince1970: 2_000))
        let notes = GoalConflicts.longTermNotes([lose, gain])
        XCTAssertEqual(notes.map(\.goalId), [gain.id], "the note sits on the newer goal")

        let alsoLose = CoachGoal(kind: .weight, title: "Lose more", baseline: 90, target: 75)
        XCTAssertTrue(GoalConflicts.longTermNotes([lose, alsoLose]).isEmpty)
    }

    func testSameTemplateWithDifferentNumbersIsNotedPerSport() {
        let template = GoalTemplateID.distanceTotal.rawValue
        let a = CoachGoal(kind: .endurance, title: "a", target: 1_000, templateId: template,
                          measure: .init(metric: .distanceTotal, sportFilter: ["Running"]))
        let b = CoachGoal(kind: .endurance, title: "b", target: 800, templateId: template,
                          measure: .init(metric: .distanceTotal, sportFilter: ["running"]))
        let cycling = CoachGoal(kind: .endurance, title: "c", target: 3_000, templateId: template,
                                measure: .init(metric: .distanceTotal, sportFilter: ["Cycling"]))
        XCTAssertEqual(GoalConflicts.longTermNotes([a, b]).count, 1)
        XCTAssertTrue(GoalConflicts.longTermNotes([a, cycling]).isEmpty, "running and cycling are two goals")
    }

    // MARK: - Templates for goals made before the catalog

    func testLegacyGoalsGetTheirUnambiguousTemplate() {
        let d = defaults()
        let store = CoachGoalStore(defaults: d)
        let periods = PeriodGoalStore(defaults: d)
        let lose = CoachGoal(kind: .weight, title: "Get sexy", baseline: 217, target: 100)
        let gain = CoachGoal(kind: .weight, title: "Bulk", baseline: 70, target: 75)
        let undirected = CoachGoal(kind: .weight, title: "Weight", baseline: 80)
        let sleep = CoachGoal(kind: .sleep, title: "Sleep", baseline: 6.8, target: 7.5)
        let run = CoachGoal(kind: .run, title: "10 km", baseline: 5, target: 10)
        var done = CoachGoal(kind: .sleep, title: "Old sleep goal")
        done.status = .achieved
        store.goals = [lose, gain, undirected, sleep, run, done]

        store.assignTemplatesToLegacyGoals(periodStore: periods, today: "2026-10-05")

        XCTAssertEqual(store.goal(id: lose.id)?.templateId, "body.weightLose")
        XCTAssertEqual(store.goal(id: lose.id)?.measure, .init(metric: .weight))
        XCTAssertEqual(store.goal(id: lose.id)?.history.last?.what, "Linked to a goal template")
        XCTAssertEqual(store.goal(id: lose.id)?.target, 100, "nothing else changes")
        XCTAssertEqual(store.goal(id: gain.id)?.templateId, "body.weightGain")
        XCTAssertNil(store.goal(id: undirected.id)?.templateId, "no target, no way to tell lose from gain")
        XCTAssertEqual(store.goal(id: sleep.id)?.templateId, "sleep.average")
        XCTAssertNil(store.goal(id: run.id)?.templateId, "a run goal's window does not match the template")
        XCTAssertNil(store.goal(id: done.id)?.templateId, "closed goals are history")
        XCTAssertTrue(periods.goals.isEmpty, "only a train-regularly goal brings a weekly goal")
    }

    func testTrainRegularlyGetsAWeeklyGoalOnce() throws {
        let d = defaults()
        let store = CoachGoalStore(defaults: d)
        let periods = PeriodGoalStore(defaults: d)
        let goal = CoachGoal(kind: .consistency, title: "Train", baseline: 2, target: 3)
        store.goals = [goal]

        store.assignTemplatesToLegacyGoals(periodStore: periods, today: "2026-10-05")
        store.assignTemplatesToLegacyGoals(periodStore: periods, today: "2026-10-06")

        let migrated = try XCTUnwrap(store.goal(id: goal.id))
        XCTAssertEqual(migrated.templateId, "training.weekly")
        XCTAssertEqual(periods.goals.count, 1, "running it again changes nothing")
        let weekly = try XCTUnwrap(periods.goals.first)
        XCTAssertEqual(weekly.metric, .workouts)
        XCTAssertEqual(weekly.period, .week)
        XCTAssertEqual(weekly.target, 3)
        XCTAssertEqual(weekly.parentGoalId, goal.id)
        XCTAssertEqual(migrated.measure?.weeklyGoalId, weekly.id)
        XCTAssertEqual(migrated.measure?.adherenceWeeks, 12)
        XCTAssertEqual(migrated.history.filter { $0.what == "Linked to a goal template" }.count, 1)
    }

    /// An open weekly workouts goal that serves nothing else is adopted rather than doubled.
    func testTrainRegularlyAdoptsAnExistingWeeklyGoal() throws {
        let d = defaults()
        let store = CoachGoalStore(defaults: d)
        let periods = PeriodGoalStore(defaults: d)
        let existing = PeriodGoal(metric: .workouts, period: .week, target: 4)
        periods.commit(existing, today: "2026-10-01")
        let goal = CoachGoal(kind: .consistency, title: "Train", target: 3)
        store.goals = [goal]

        store.assignTemplatesToLegacyGoals(periodStore: periods, today: "2026-10-05")

        XCTAssertEqual(periods.goals.count, 1)
        XCTAssertEqual(periods.goals.first?.parentGoalId, goal.id)
        XCTAssertEqual(store.goal(id: goal.id)?.measure?.weeklyGoalId, existing.id)
    }

    func testKeepYourWeightIsAMaintainGoal() {
        XCTAssertEqual(GoalCatalog.template(.weightMaintain)?.shape, .maintain)
        XCTAssertEqual(GoalCatalog.template(.weightLose)?.shape, .target)
    }
}
