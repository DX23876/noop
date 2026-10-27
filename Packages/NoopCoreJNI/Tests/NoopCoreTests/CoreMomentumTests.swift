import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// Momentum on Android (parity plan 1.2): the core assembles the dashboard context from the store and the goals,
/// and the shared builder and resolver word and rank it.
@MainActor
final class CoreMomentumTests: XCTestCase {
    func testLogicalDayClockReadDoesNotRequireAnOpenStore() async throws {
        let before = LogicalDay.key(Date())
        let json = await CoreCall.run("momentum.day", "{}")
        let output = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        XCTAssertTrue(Set([before, LogicalDay.key(Date())]).contains(try XCTUnwrap(output["day"])))
    }

    func testScoredDayWithAStepGoalReadsRecoveryAndSteps() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let now = Date()
        let today = LogicalDay.key(now)
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: today, totalSleepMin: 450, efficiency: 0.9, deepMin: 90, remMin: 100,
                        lightMin: 260, disturbances: 3, restingHr: 52, avgHrv: 70, recovery: 81,
                        strain: 30, exerciseCount: 0, steps: 3_200),
        ], deviceId: "my-whoop")
        let saved = await CoreGoals.saveDaily(store: store, slot: "steps", value: 10_000, runs: "ongoing",
                                              endsOn: nil, weekdays: Array(1...7), showsAsRing: true)
        XCTAssertTrue(saved.ok)
        let settings = CoreGoals.Settings(profileSex: "male", lastSync: nil, agelessEnabled: false,
                                          dismissedWorkoutSpans: [])
        let output = try await CoreMomentum.feed(reader: reader, settings: settings, hrvEpoch: 0, recoveryEpoch: 0,
                                                 snoozedRaw: "", lastKind: "", lastAt: 0, now: now)
        XCTAssertFalse(output.messages.isEmpty)
        let kinds = Set(output.messages.map(\.kind))
        XCTAssertTrue(kinds.contains("recoveryRead"), "kinds: \(kinds)")
        XCTAssertTrue(output.messages.allSatisfy { !$0.headline.isEmpty })

        let snoozed = CoreMomentum.snooze(kind: "recoveryRead", snoozedRaw: "", now: now)
        let hidden = try await CoreMomentum.feed(reader: reader, settings: settings, hrvEpoch: 0, recoveryEpoch: 0,
                                                 snoozedRaw: snoozed, lastKind: "", lastAt: 0, now: now)
        XCTAssertFalse(hidden.messages.contains { $0.kind == "recoveryRead" })
    }
}
