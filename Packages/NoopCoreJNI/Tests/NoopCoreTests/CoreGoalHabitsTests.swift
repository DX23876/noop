import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// Habit and hydration goals on Android (parity plan 1.3): the habit question and the hydration opt-in come
/// from the host, and the core counts the shared journal and water inputs as the Apple tracker does.
@MainActor
final class CoreGoalHabitsTests: XCTestCase {
    func testHabitGoalNeedsAQuestionAndCountsTheWantedAnswers() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let settings = CoreGoalEnergy.settings(["sex": "male"])
        let now = Date()
        let today = StoreReader.localDayKey(now)
        _ = try await store.upsertJournal([
            JournalEntry(day: today, question: "Alcohol", answeredYes: false, notes: nil),
            JournalEntry(day: today, question: "Stretching", answeredYes: true, notes: nil),
        ], deviceId: JournalRead.nativeSource)

        let missing = await CoreGoals.addPeriodGoal(store: store, metric: "habitDays", period: "week", target: 5,
                                                    threshold: nil, habitKey: "  ", now: now)
        XCTAssertEqual(missing.error, "invalid")
        let avoid = await CoreGoals.addPeriodGoal(store: store, metric: "habitDays", period: "week", target: 5,
                                                  threshold: nil, habitKey: "Alcohol", habitWantsYes: false, now: now)
        XCTAssertTrue(avoid.ok)

        let output = try await CoreGoals.snapshot(reader: reader, settings: settings, now: now)
        let goal = try XCTUnwrap(output.period.first { $0.metric == "habitDays" })
        XCTAssertEqual(goal.current, 1)
        XCTAssertEqual(goal.habitKey, "Alcohol")
        XCTAssertEqual(goal.habitWantsYes, false)
    }

    func testHydrationGoalFollowsTheHostOptIn() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let off = try await CoreGoals.setup(reader: reader, settings: CoreGoalEnergy.settings([:]))
        XCTAssertEqual(off.metrics.first { $0.metric == "hydrationDays" }?.available, false)
        let on = try await CoreGoals.setup(reader: reader, settings: CoreGoalEnergy.settings(["hydrationEnabled": true]))
        XCTAssertEqual(on.metrics.first { $0.metric == "hydrationDays" }?.available, true)
    }

    /// The shape `CoreGoalHost.kt` writes from the Android catalog: Swift's own `JournalCatalogItem` coding.
    func testAndroidCatalogWireDecodesWithItsAliases() throws {
        let wire = #"[{"canonical":"Alcohol","displayName":"Drinks","kind":{"numeric":{"unitLabel":"units"}},"#
            + #""group":"lifestyle","sortIndex":0,"hidden":false,"custom":false,"aliases":["Had alcohol"]},"#
            + #"{"canonical":"Stretching","kind":{"bool":{}},"group":"other","sortIndex":1,"hidden":true,"#
            + #""custom":true,"aliases":[]}]"#
        let settings = CoreGoalEnergy.settings(["journalCatalog": wire])
        XCTAssertEqual(settings.journalAliases[JournalRead.normalize("Had alcohol")], "Alcohol")
        let items = try JSONDecoder().decode([JournalCatalogItem].self, from: Data(wire.utf8))
        XCTAssertEqual(items.map(\.kind), [.numeric(unitLabel: "units"), .bool])
        XCTAssertEqual(items.map(\.group), [.lifestyle, .other])
    }
}
