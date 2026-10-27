import Foundation
import XCTest
import StrandAnalytics
import WhoopStore
@testable import StrandCore

final class GoalSourceReadTests: XCTestCase {
    func testMergedJournalUsesNativeAnswerAndKeepsOriginalRows() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        let day = "2026-10-27"
        let imported = JournalEntry(day: day, question: "Coffee", answeredYes: true, notes: "export")
        let native = JournalEntry(day: day, question: "  CAFFEINE\n", answeredYes: false, notes: "corrected", numericValue: 0)
        _ = try await store.upsertJournal([imported], deviceId: "my-whoop")
        _ = try await store.upsertJournal([native], deviceId: JournalRead.nativeSource)
        let rows = await JournalRead.entries(reader: reader, from: day, to: day,
            aliases: ["caffeine": "Coffee"], aliasOrder: ["caffeine": 0])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.question, "Coffee")
        XCTAssertEqual(rows.first?.answeredYes, false)
        XCTAssertEqual(rows.first?.numericValue, 0)
        XCTAssertEqual(rows.first?.notes, "corrected")
        let untouched = try await store.journalEntries(deviceId: JournalRead.nativeSource, from: day, to: day)
        XCTAssertEqual(untouched, [native])
    }

    func testAliasOrderDoesNotCombineContradictoryAnswers() {
        let a = JournalEntry(day: "2026-10-27", question: "First", answeredYes: false, notes: "first")
        let b = JournalEntry(day: a.day, question: "Second", answeredYes: true, notes: "second")
        let rows = JournalRead.fold(imported: [b, a], native: [], aliases: ["first": "Habit", "second": "Habit"],
            aliasOrder: ["first": 0, "second": 1])
        XCTAssertEqual(rows.first?.answeredYes, false)
        XCTAssertEqual(rows.first?.notes, "first")
        XCTAssertEqual(JournalRead.normalize("  Did\u{00A0}you\nDRINK?  "), "did you drink?")
    }

    func testHydrationSumsManualAndImportedOnceAndFillsMissingDays() async throws {
        let store = try await WhoopStore.inMemory()
        let now = WeightSeries.date(forDay: "2026-10-27")!
        _ = try await store.upsertMetricSeries([.init(day: "2026-10-27", key: HydrationRead.manualKey, value: 1500)],
                                               deviceId: HydrationRead.sourceId)
        let imported = MetricPoint(day: "2026-10-27", key: HydrationRead.importedKey, value: 750)
        _ = try await store.upsertMetricSeries([imported], deviceId: HydrationRead.sourceId)
        _ = try await store.upsertMetricSeries([imported], deviceId: HydrationRead.sourceId)
        let rows = await HydrationRead.history(store: store, days: 2, now: now)
        XCTAssertEqual(rows.map(\.day), ["2026-10-26", "2026-10-27"])
        XCTAssertEqual(rows.map(\.value), [0, 2250])
        let manual = try await store.metricSeries(deviceId: HydrationRead.sourceId, key: HydrationRead.manualKey,
                                                  from: "2026-10-27", to: "2026-10-27")
        XCTAssertEqual(manual.first?.value, 1500)
    }

    func testExploreUsesComputedGapsThenImportedActiveStrapPriority() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "owned-strap", registeredWhoopIds: [])
        for (source, value) in [("my-whoop-noop", 40.0), ("owned-strap-noop", 50), ("my-whoop", 60), ("owned-strap", 70)] {
            _ = try await store.upsertMetricSeries([.init(day: "2026-10-27", key: "rhr_primary_session", value: value)], deviceId: source)
        }
        _ = try await store.upsertMetricSeries([.init(day: "2026-10-26", key: "rhr_primary_session", value: 55)],
                                               deviceId: "owned-strap-noop")
        let rows = await reader.exploreSeries(key: "rhr_primary_session", source: "my-whoop",
            from: "2026-10-26", to: "2026-10-27", dailyRows: [], suppressedSleepWakeDays: [])
        XCTAssertEqual(rows.map(\.value), [55, 70])
        _ = try await store.upsertMetricSeries([.init(day: "2026-10-27", key: "sleep_total_min", value: 420)],
                                               deviceId: "owned-strap-noop")
        let hidden = await reader.exploreSeries(key: "sleep_total_min", source: "my-whoop",
            from: "2026-10-26", to: "2026-10-27", dailyRows: [], suppressedSleepWakeDays: ["2026-10-27"])
        XCTAssertTrue(hidden.isEmpty)
    }
}
