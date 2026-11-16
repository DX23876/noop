import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// An op that writes must not answer `ok` for a write it did not watch land.
///
/// This is the gym report of 2026-11-16 one layer out. A tick came back as saved although the store had
/// refused it, the finish then read the store and told the wearer to tick sets that were already ticked.
/// `changeDraft` was fixed where it happened; these four ops have the same shape — `try?` around the
/// write, then a flat `ok` or `true` — and each one feeds a screen that would believe it.
///
/// The refusal is real rather than mocked: the same database, opened so that SQLite rejects writes. On a
/// phone it is a busy timeout under a long backfill write, or a full disk.
final class RefusedWriteTests: XCTestCase {

    private func refusingStore() async throws -> WhoopStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sqlite").path
        _ = try await WhoopStore(path: path)     // creates and migrates the file
        return try WhoopStore.readOnly(path: path)
    }

    func testAFavouriteTheStoreRefusedIsNotAnsweredWithOk() async throws {
        let store = try await refusingStore()
        let answer = await CoreFood.run("food.setFavourite",
                                        args: ["foodId": "apple", "name": "Apple", "on": true], store: store)
        XCTAssertEqual(answer, #"{"ok":false}"#, "a star the store did not keep is not a star")
    }

    func testAHealthIdTheStoreRefusedIsNotAnsweredWithOk() async throws {
        let store = try await refusingStore()
        let answer = await CoreFood.run("food.setHealthId",
                                        args: ["id": "entry", "healthId": "uuid"], store: store)
        XCTAssertEqual(answer, #"{"ok":false}"#)
    }

    func testADayMarkedCompleteTheStoreRefusedIsNotAnsweredWithOk() async throws {
        let store = try await refusingStore()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let answer = await CoreDietPlan.run("food.planSetDayComplete",
                                            args: ["day": "2026-11-16", "complete": true],
                                            store: store, reader: reader)
        XCTAssertEqual(answer, #"{"ok":false}"#,
                       "only marked days count toward the real burn, so a lost mark changes a number later")
    }

    func testAMergeTheStoreRefusedIsNotAnsweredWithTrue() async throws {
        let store = try await refusingStore()
        let merged = await CoreTrainingLoad.decidePair(store: store, ids: ["a|1", "b|2"], merge: true)
        XCTAssertFalse(merged, "the two records are still two")
    }

    /// The same question asked the other way round: with a store that accepts writes, every one of them
    /// still says yes. A gate that answers no to everything would pass the four tests above.
    func testAStoreThatAcceptsWritesStillGetsAYes() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let favourite = await CoreFood.run("food.setFavourite",
                                           args: ["foodId": "apple", "name": "Apple", "on": true], store: store)
        XCTAssertEqual(favourite, #"{"ok":true}"#)
        let day = await CoreDietPlan.run("food.planSetDayComplete",
                                         args: ["day": "2026-11-16", "complete": true],
                                         store: store, reader: reader)
        XCTAssertEqual(day, #"{"ok":true}"#)
        let merged = await CoreTrainingLoad.decidePair(store: store, ids: ["a|1", "b|2"], merge: true)
        XCTAssertTrue(merged)
    }
}
