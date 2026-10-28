import Foundation
import XCTest
import WhoopStore
@testable import NoopCore

@MainActor
final class GoalTrackingModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ day: String) -> Date {
        let parts = day.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }
    private func source(now: Date, steps: [String: Int]) -> GoalTrackingModel.Source {
        var periods = PeriodGoalInputs()
        periods.stepsByDay = steps
        return .init(workouts: [], allWorkouts: [], weights: [], stress: [], days: [], hardSetsPerWeek: nil,
            activeKcalByDay: [:], stepsByDay: steps, journalByDay: [:], periodInputs: periods,
            levelSeries: [:], calendar: calendar)
    }

    func testOneRefreshAgreesOnDailyCompletionAndWeeklyProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let now = date("2026-10-27")
        let daily = GoalAction(title: "Walk", requirement: .steps(minimum: 8000), goalIds: [],
            createdAt: date("2026-10-01"))
        let weekly = PeriodGoal(metric: .stepDays, period: .week, target: 3, threshold: 8000,
            createdAt: date("2026-10-01"))
        try await CoreGoalState.change(store: store) { context in
            context.actions.upsert(daily)
            context.periods.commit(weekly, today: "2026-10-01")
            let model = GoalTrackingModel()
            model.refresh(source: source(now: now, steps: ["2026-10-26": 8500, "2026-10-27": 9000]),
                now: now, goals: [], proposals: [], unresolved: [], actions: context.actions.actions,
                checkoffs: [], contributions: [], dismissedWorkoutKeys: [])
            XCTAssertEqual(model.todayActions.count, 1)
            XCTAssertTrue(model.todayActions[0].isCompleted)
            XCTAssertEqual(model.periodSnapshots.first?.result.current, 2)
            XCTAssertEqual(model.lastUpdated, now)
        }
    }

    func testFinishedPeriodFreezesOnceAndLaterReadingsDoNotRewriteHistory() async throws {
        let store = try await WhoopStore.inMemory()
        let now = date("2026-10-27")
        let weekly = PeriodGoal(metric: .stepDays, period: .week, target: 1, threshold: 8000,
            createdAt: date("2026-10-19"))
        try await CoreGoalState.change(store: store) { $0.periods.commit(weekly, today: "2026-10-19") }
        func refresh(_ steps: [String: Int]) async throws -> [PeriodGoalResult] {
            try await CoreGoalState.change(store: store) { context in
                let model = GoalTrackingModel()
                model.refresh(source: source(now: now, steps: steps), now: now, goals: [], proposals: [],
                    unresolved: [], actions: [], checkoffs: [], contributions: [], dismissedWorkoutKeys: [])
                return context.periods.results
            }
        }
        let before = try await refresh(["2026-10-20": 9000, "2026-10-27": 1000])
        let frozen = try XCTUnwrap(before.first { $0.periodStart == "2026-10-19" })
        XCTAssertEqual(frozen.outcome, .achieved)
        let after = try await refresh(["2026-10-20": 0, "2026-10-27": 1000])
        XCTAssertEqual(after, before)
    }
}
