import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// The goal notifications on Android (parity plan 2.3): the core decides as Apple's `GoalEventNotifier` does, from
/// the same `GoalEventPlan`, and the state it hands back keeps an event from being told twice.
@MainActor
final class CoreGoalNoticesTests: XCTestCase {
    private let settings = CoreGoals.Settings(profileSex: "male", lastSync: nil, agelessEnabled: false,
                                              dismissedWorkoutSpans: [])

    func testAReachedStepGoalIsToldOnceAndNotInQuietHours() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        // Noon, so the goal's day and the notice's day are the same whenever the suite runs.
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        let today = LogicalDay.key(now)
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: today, totalSleepMin: 450, efficiency: 0.9, deepMin: 90, remMin: 100,
                        lightMin: 260, disturbances: 3, restingHr: 52, avgHrv: 70, recovery: 81,
                        strain: 30, exerciseCount: 0, steps: 12_000),
        ], deviceId: "my-whoop")
        let saved = await CoreGoals.saveDaily(store: store, slot: "steps", value: 10_000, runs: "ongoing",
                                              endsOn: nil, weekdays: Array(1...7), showsAsRing: true, now: now)
        XCTAssertTrue(saved.ok)

        // Quiet hours: nothing said, but the event is marked as handled, so it is never sent hours later.
        var host = CoreGoalNotices.Host(kinds: ["reached", "streak", "badge", "milestone"], quiet: true,
                                        eveningMinute: 19 * 60, workoutInProgress: false, appIsActive: false,
                                        state: nil)
        let quiet = try await CoreGoalNotices.evaluate(reader: reader, settings: settings, host: host, now: now)
        XCTAssertTrue(quiet.messages.isEmpty)
        host.quiet = false
        host.state = quiet.state
        let after = try await CoreGoalNotices.evaluate(reader: reader, settings: settings, host: host, now: now)
        XCTAssertTrue(after.messages.isEmpty)

        // A fresh state outside the quiet hours tells it, once.
        host.state = nil
        let told = try await CoreGoalNotices.evaluate(reader: reader, settings: settings, host: host, now: now)
        XCTAssertEqual(told.messages.count, 1)
        XCTAssertTrue(told.messages[0].title.contains("reached"), told.messages[0].title)
        host.state = told.state
        let again = try await CoreGoalNotices.evaluate(reader: reader, settings: settings, host: host, now: now)
        XCTAssertTrue(again.messages.isEmpty)
    }
}
