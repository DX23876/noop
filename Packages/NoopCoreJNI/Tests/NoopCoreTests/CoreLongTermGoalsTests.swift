import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// The Android long-term goal setup and page (parity plan 2.3): the shared draft suggests, the core creates the goal
/// with its weekly goal, asks before measuring the same thing twice, and the page's actions reach both.
@MainActor
final class CoreLongTermGoalsTests: XCTestCase {
    private let settings = CoreGoals.Settings(profileSex: "female", lastSync: nil, agelessEnabled: false,
                                              dismissedWorkoutSpans: [])

    func testCollectWorkoutsGoalIsSuggestedCreatedAndManaged() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let catalog = try await CoreLongTermGoals.catalog(reader: reader, settings: settings, profileWeightKg: 70)
        XCTAssertFalse(catalog.areas.isEmpty)
        let template = try XCTUnwrap(catalog.templates.first { $0.id == "endurance.workoutsTotal" })
        XCTAssertTrue(template.available)

        var state = CoreLongTermGoals.State()
        state.template = template.id
        let draft = try await CoreLongTermGoals.draft(reader: reader, settings: settings, profileWeightKg: 70,
                                                      state: state, action: "suggest")
        XCTAssertEqual(draft.shape, "sum")
        XCTAssertGreaterThan(draft.state.target, 0)
        XCTAssertEqual(draft.weeklyMetricOfGoal, "workouts")

        // The draft Kotlin parses (`CoreLongTermGoalsTest`), pinned by shape; NOOP_UPDATE_TRAINING_FIXTURES=1 rewrites it.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/goals/long-term-draft.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try data.write(to: file) }
        let pinned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(pinned.keys), Set(fresh.keys))

        let created = await CoreLongTermGoals.create(reader: reader, settings: settings, profileWeightKg: 70,
                                                     state: draft.state, replacing: nil, keepBoth: false, riskReason: nil)
        XCTAssertTrue(created.ok)
        let id = try XCTUnwrap(created.goalId)
        let again = await CoreLongTermGoals.create(reader: reader, settings: settings, profileWeightKg: 70,
                                                   state: draft.state, replacing: nil, keepBoth: false, riskReason: nil)
        XCTAssertEqual(again.error, "sameMeasure")
        XCTAssertEqual(again.existingId, id)

        var output = try await CoreGoals.snapshot(reader: reader, settings: settings)
        XCTAssertEqual(output.longTerm.map(\.id), [id])
        let weekly = try XCTUnwrap(output.period.first { $0.parentGoalId == id })
        XCTAssertEqual(weekly.metric, "workouts")

        // The page from the shared content: a sum goal has a hero with three figures and a milestone route.
        let loaded = try await CoreLongTermGoals.page(reader: reader, settings: settings, id: id)
        let page = try XCTUnwrap(loaded)
        XCTAssertEqual(page.figures.count, 3)
        XCTAssertEqual(page.band?.kind, "milestones")
        XCTAssertFalse(page.statusText.isEmpty)
        XCTAssertFalse(page.insights.isEmpty)
        XCTAssertFalse(page.pinned)
        XCTAssertFalse(page.reached)
        XCTAssertEqual(page.raise.count, 24)
        XCTAssertEqual(page.raise.map(\.value), page.raise.map(\.value).sorted())
        let pageData = try encoder.encode(page)
        let pageFile = file.deletingLastPathComponent().appendingPathComponent("long-term-page.json")
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try pageData.write(to: pageFile) }
        let pinnedPage = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pageFile)) as? [String: Any])
        let freshPage = try XCTUnwrap(JSONSerialization.jsonObject(with: pageData) as? [String: Any])
        XCTAssertEqual(Set(pinnedPage.keys), Set(freshPage.keys))

        let pin = await CoreLongTermGoals.change(store: store, id: id, action: "pin", reason: nil)
        XCTAssertTrue(pin.ok)
        let higher = page.raise[0].value
        let raised = await CoreLongTermGoals.change(store: store, id: id, action: "raise", reason: nil, value: higher)
        XCTAssertTrue(raised.ok)
        let reloaded = try await CoreLongTermGoals.page(reader: reader, settings: settings, id: id)
        let changed = try XCTUnwrap(reloaded)
        XCTAssertTrue(changed.pinned)
        XCTAssertEqual(changed.raise.first.map { $0.value > higher }, true)

        let paused = await CoreLongTermGoals.change(store: store, id: id, action: "pause", reason: "travel")
        XCTAssertTrue(paused.ok)
        output = try await CoreGoals.snapshot(reader: reader, settings: settings)
        XCTAssertEqual(output.longTerm.first?.status, "paused")
        XCTAssertEqual(output.period.first { $0.parentGoalId == id }?.status, "paused")

        let removed = await CoreLongTermGoals.change(store: store, id: id, action: "remove", reason: nil)
        XCTAssertTrue(removed.ok)
        output = try await CoreGoals.snapshot(reader: reader, settings: settings)
        XCTAssertTrue(output.longTerm.isEmpty)
    }
}
