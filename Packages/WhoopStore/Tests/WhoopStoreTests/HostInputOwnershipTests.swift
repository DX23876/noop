import Foundation
import XCTest
@testable import WhoopStore

final class HostInputOwnershipTests: XCTestCase {
    private let day = "2026-10-27"
    private func input(_ value: Double = 0) -> LegacyJournalInput {
        .init(deviceId: "noop-journal", day: day, question: " Caffeine\n", answeredYes: false,
              notes: "Original note", numericValue: value)
    }

    func testAdoptionPreservesOriginalsAndNeverReplaysDeletedInputs() async throws {
        let store = try await WhoopStore.inMemory()
        let applied = try await store.adoptAndroidJournalHydration(journal: [input()], hydration: [
            .init(day: day, key: "hydration", value: 200), .init(day: day, key: "hydrationImported", value: 500)])
        XCTAssertTrue(applied)
        let journal = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(journal.first?.question, " Caffeine\n")
        XCTAssertEqual(journal.first?.numericValue, 0)
        XCTAssertEqual(journal.first?.answeredYes, false)
        XCTAssertEqual(journal.first?.notes, "Original note")
        _ = try await store.deleteJournal(deviceId: "noop-journal", day: day, question: " Caffeine\n")
        let replayed = try await store.adoptAndroidJournalHydration(journal: [input(5)], hydration: [
            .init(day: day, key: "hydration", value: 900)])
        XCTAssertFalse(replayed)
        let after = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertTrue(after.isEmpty)
        let water = try await store.metricSeries(deviceId: "hydration", key: "hydration", from: day, to: day)
        XCTAssertEqual(water.first?.value, 200)
    }

    func testExistingCoreValuesWinAndFailureRollsBackTheWholeSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertJournal([.init(day: day, question: " Caffeine\n", answeredYes: true,
                                                notes: "Newer", numericValue: 10)], deviceId: "noop-journal")
        do {
            _ = try await store.adoptAndroidJournalHydration(journal: [input(),
                .init(deviceId: "noop-journal", day: day, question: "Transient", answeredYes: true,
                      notes: nil, numericValue: nil)], hydration: [
                .init(day: day, key: "hydration", value: 200), .init(day: day, key: "other", value: 1)])
            XCTFail("Invalid input must abort the snapshot")
        } catch HostInputOwnershipError.invalidHydration {}
        let owned = try await store.ownsAndroidJournalHydration()
        XCTAssertFalse(owned)
        let rolledBack = try await store.metricSeries(deviceId: "hydration", key: "hydration", from: day, to: day)
        XCTAssertTrue(rolledBack.isEmpty)
        let retainedJournal = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(retainedJournal.map(\.question), [" Caffeine\n"])
        _ = try await store.adoptAndroidJournalHydration(journal: [input()], hydration: [])
        let retained = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(retained.first?.numericValue, 10)
        XCTAssertEqual(retained.first?.notes, "Newer")
    }

    func testRestoreSealsLegacyAdoptionEvenWithoutGoalSettings() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        try WhoopStore.prepareRestoredGoalPreferenceState(at: path.path, sealAndroidInputs: true) { _ in nil }
        let restored = try await WhoopStore(path: path.path)
        let owned = try await restored.ownsAndroidJournalHydration()
        XCTAssertTrue(owned)
        let replayed = try await restored.adoptAndroidJournalHydration(journal: [input()], hydration: [])
        XCTAssertFalse(replayed)
        let journal = try await restored.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertTrue(journal.isEmpty)
    }
}
