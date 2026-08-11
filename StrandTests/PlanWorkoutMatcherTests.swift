import XCTest
import WhoopStore
@testable import Strand

final class PlanWorkoutMatcherTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func date(_ value: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: value)!
    }

    private func workout(_ start: String, sport: String = "Running") -> WorkoutRow {
        let s = Int(date(start).timeIntervalSince1970)
        return WorkoutRow(startTs: s, endTs: s + 3600, sport: sport, source: "apple-health",
                          durationS: 3600, energyKcal: nil, avgHr: 140, maxHr: 170,
                          strain: 48, distanceM: 10_000, zonesJSON: nil, notes: nil)
    }

    private func commitment(day: String = "2026-08-10", sport: String = "Easy run",
                            time: Date? = nil) -> PlanProposal {
        PlanProposal(day: day, time: time, sport: sport, intent: .easy, status: .accepted)
    }

    func testUniqueSameFamilyWorkoutCompletesAutomatically() {
        let plan = commitment()
        let result = PlanWorkoutMatcher.match(
            proposals: [plan], workouts: [workout("2026-08-10 08:00")],
            now: date("2026-08-11 12:00"), calendar: calendar)
        XCTAssertEqual(result.automatic.map(\.proposalId), [plan.id])
        XCTAssertTrue(result.resolutions.isEmpty)
    }

    func testTwoPlausibleWorkoutsRequireConfirmation() {
        let plan = commitment()
        let result = PlanWorkoutMatcher.match(
            proposals: [plan],
            workouts: [workout("2026-08-10 08:00"), workout("2026-08-10 18:00")],
            now: date("2026-08-11 12:00"), calendar: calendar)
        XCTAssertTrue(result.automatic.isEmpty)
        XCTAssertEqual(result.resolutions.first?.kind, .candidates)
        XCTAssertEqual(result.resolutions.first?.candidates.count, 2)
    }

    func testOneWorkoutCannotCompleteTwoPlans() {
        let first = commitment(), second = commitment()
        let result = PlanWorkoutMatcher.match(
            proposals: [first, second], workouts: [workout("2026-08-10 08:00")],
            now: date("2026-08-11 12:00"), calendar: calendar)
        XCTAssertTrue(result.automatic.isEmpty)
        XCTAssertEqual(Set(result.resolutions.map(\.proposalId)), Set([first.id, second.id]))
    }

    func testGenericWorkoutIsNeverAutomatic() {
        let plan = commitment(time: date("2026-08-10 08:00"))
        let result = PlanWorkoutMatcher.match(
            proposals: [plan], workouts: [workout("2026-08-10 08:15", sport: "Workout")],
            now: date("2026-08-11 12:00"), calendar: calendar)
        XCTAssertTrue(result.automatic.isEmpty)
        XCTAssertEqual(result.resolutions.first?.kind, .candidates)
    }

    func testPastPlanWithNoWorkoutIsNeutralOverdueResolution() {
        let plan = commitment()
        let result = PlanWorkoutMatcher.match(
            proposals: [plan], workouts: [], now: date("2026-08-11 12:00"), calendar: calendar)
        XCTAssertTrue(result.automatic.isEmpty)
        XCTAssertEqual(result.resolutions, [
            .init(proposalId: plan.id, kind: .overdue, candidates: [])
        ])
    }

    func testRejectedCandidateDoesNotReturn() {
        let row = workout("2026-08-10 08:00", sport: "Workout")
        var plan = commitment(time: date("2026-08-10 08:00"))
        plan.rejectedWorkoutKeys = [PlanWorkoutReference(row).workoutKey]
        let result = PlanWorkoutMatcher.match(
            proposals: [plan], workouts: [row], now: date("2026-08-11 12:00"), calendar: calendar)
        XCTAssertEqual(result.resolutions.first?.kind, .overdue)
        XCTAssertTrue(result.resolutions.first?.candidates.isEmpty ?? false)
    }

    func testCompletionEvidenceAndRejectedKeysRoundTrip() throws {
        let row = PlanWorkoutReference(workout("2026-08-10 08:00"))
        var plan = commitment()
        plan.completionEvidence = row.completionEvidence(method: .confirmed,
                                                          matchedAt: date("2026-08-11 12:00"))
        plan.rejectedWorkoutKeys = ["old-candidate"]
        let decoded = try JSONDecoder().decode(PlanProposal.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.completionEvidence, plan.completionEvidence)
        XCTAssertEqual(decoded.rejectedWorkoutKeys, ["old-candidate"])
    }

    func testProposePlanToolOffersOptionalGoalId() {
        let schema = CoachTool.proposePlan.inputSchema
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["goal_id"])
        XCTAssertFalse((schema["required"] as? [String] ?? []).contains("goal_id"))
    }

    @MainActor
    func testLegacyAttributionMigratesOnlyWithOneEligibleGoal() {
        let suite = "PlanGoalMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CoachPlanStore(loading: false)
        store.addUserSession(day: "2026-08-10", time: nil, sport: "Running", intent: .easy)
        store.complete(store.proposals[0].id)
        let goal = CoachGoal(kind: .run, title: "10k",
                             createdAt: date("2026-08-01 10:00"))

        PlanGoalAttributionMigration.runIfNeeded(store: store, goals: [goal], defaults: defaults)

        XCTAssertEqual(store.proposals[0].goalId, goal.id)
        XCTAssertTrue(defaults.bool(forKey: PlanGoalAttributionMigration.defaultsKey))
    }

    @MainActor
    func testLegacyAttributionLeavesAmbiguousSessionGeneral() {
        let suite = "PlanGoalMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CoachPlanStore(loading: false)
        store.addUserSession(day: "2026-08-10", time: nil, sport: "Running", intent: .easy)
        store.complete(store.proposals[0].id)
        let first = CoachGoal(kind: .run, title: "10k", createdAt: date("2026-08-01 10:00"))
        let second = CoachGoal(kind: .sleep, title: "Sleep", createdAt: date("2026-08-01 10:00"))

        PlanGoalAttributionMigration.runIfNeeded(store: store, goals: [first, second], defaults: defaults)

        XCTAssertNil(store.proposals[0].goalId)
    }
}
