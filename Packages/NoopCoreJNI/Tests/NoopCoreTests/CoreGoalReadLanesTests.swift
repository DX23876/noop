import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

@MainActor
final class CoreGoalReadLanesTests: XCTestCase {
    private let today = "2026-10-27"
    private var now: Date { WeightSeries.date(forDay: today)! }
    private var settings: CoreGoals.Settings {
        .init(profileSex: "male", lastSync: nil, agelessEnabled: true, dismissedWorkoutSpans: [])
    }

    func testVO2maxUsesValidManualReadingThenHealthAfterExpiry() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        _ = try await store.upsertMetricSeries([.init(day: "2026-10-26", key: "vo2max", value: 42),
            .init(day: "2026-10-28", key: "vo2max", value: 99)], deviceId: "apple-health")
        var selected = settings
        selected.energyManualVO2 = .init(vo2max: 50, day: "2026-10-01", weightKg: nil)
        let host = CoreGoals.Host(reader: reader, settings: selected, motivationEnabled: false, now: now)
        let manual = await host.goalLevelSeries(metrics: [.vo2max])
        XCTAssertEqual(manual[.vo2max]?.map(\.value), [50])
        selected.energyManualVO2 = .init(vo2max: 50, day: "2024-10-01", weightKg: nil)
        let expired = CoreGoals.Host(reader: reader, settings: selected, motivationEnabled: false, now: now)
        let health = await expired.goalLevelSeries(metrics: [.vo2max])
        XCTAssertEqual(health[.vo2max]?.map(\.value), [42])
    }

    func testSleepConsistencyReadsStoredComputedNights() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        var sessions: [CachedSleepSession] = []
        // Fixed 24 h spacing isolates the shared timing algorithm from local-clock fixture construction.
        for back in 0...5 {
            let wake = Int(now.timeIntervalSince1970) - back * 86_400 - 4 * 3_600
            sessions.append(.init(startTs: wake - 8 * 3_600, endTs: wake, efficiency: 1, restingHr: 55,
                                  avgHrv: 60, stagesJSON: nil))
        }
        _ = try await store.upsertSleepSessions(sessions, deviceId: "owned-strap-noop")
        let host = CoreGoals.Host(reader: reader, settings: settings, motivationEnabled: false, now: now)
        let values = await host.goalLevelSeries(metrics: [.sleepConsistency])
        XCTAssertFalse(values[.sleepConsistency, default: []].isEmpty)
        XCTAssertEqual(values[.sleepConsistency]?.last?.value, 100)
    }

    func testJournalAndHydrationLanesReadTheCoreStore() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        _ = try await store.upsertJournal([.init(day: today, question: "Walked", answeredYes: true, notes: nil)], deviceId: "noop-journal")
        _ = try await store.upsertMetricSeries([.init(day: today, key: HydrationRead.manualKey, value: 4000)], deviceId: HydrationRead.sourceId)
        var selected = settings
        selected.hydrationEnabled = true
        let host = CoreGoals.Host(reader: reader, settings: selected, motivationEnabled: false, now: now)
        let journal = await host.goalJournalEntries(days: 1)
        let hydration = await host.goalHydrationHistory(days: 1, now: now)
        XCTAssertEqual(journal.first?.question, "Walked")
        XCTAssertEqual(hydration.first?.value, 4000)
        XCTAssertTrue(host.goalHostState().hydrationEnabled)
        try await CoreGoalState.change(store: store) { context in
            context.periods.commit(.init(metric: .habitDays, period: .week, target: 3,
                habitKey: "Walked", createdAt: now), today: today)
            context.periods.commit(.init(metric: .hydrationDays, period: .week, target: 3,
                createdAt: now), today: today)
        }
        let output = try await CoreGoals.snapshot(reader: reader, settings: selected, now: now)
        XCTAssertEqual(output.period.first { $0.metric == "habitDays" }?.current, 1)
        XCTAssertEqual(output.period.first { $0.metric == "hydrationDays" }?.current, 1)
    }
}
