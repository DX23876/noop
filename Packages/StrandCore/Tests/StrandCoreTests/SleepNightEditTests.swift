import XCTest
import WhoopStore
@testable import StrandCore

/// The shared night editing (`SleepNightEdit`).
///
/// The case that brought this code into being is the first test: a night stored only in the COMPUTED
/// lane. The Apple apps could always correct one; Android looked its rows up a second time in the
/// imported lane alone, found nothing, and said nothing, so a wearer whose recent nights NOOP scores
/// itself could not correct a single one of them (2026-11-21). Both platforms now come through here.
final class SleepNightEditTests: XCTestCase {
    private let imported = "my-whoop"
    private let computed = "my-whoop-noop"
    private var ownerIds: [String] { [computed, imported] }

    /// A night at a fixed instant, so nothing here depends on the clock the test runs at.
    private let bed = 1_700_000_000
    private var wake: Int { bed + 8 * 3_600 }
    private var now: Int { wake + 3_600 }

    private func session(start: Int, end: Int) -> CachedSleepSession {
        .init(startTs: start, endTs: end, efficiency: 0.9, restingHr: 52, avgHrv: 60,
              stagesJSON: "[{\"start\":\(start),\"end\":\(end),\"stage\":\"light\"}]")
    }

    private func storedRow(_ store: WhoopStore, _ deviceId: String,
                           _ startTs: Int) async throws -> CachedSleepSession? {
        try await store.sleepSessions(deviceId: deviceId, from: startTs - 10, to: startTs + 10, limit: 4)
            .first { $0.startTs == startTs }
    }

    func testCorrectsANightThatOnlyTheComputedLaneHolds() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: computed)
        let keys = [SleepNightEdit.BlockKey(deviceId: computed, startTs: bed)]

        let group = await SleepNightEdit.rows(store: store, ownerIds: ownerIds, keys: keys)
        XCTAssertEqual(group.count, 1, "the night's own key must find its row in the computed lane")

        let result = await SleepNightEdit.editTimes(store: store, ownerIds: ownerIds, group: group,
                                                    newStartTs: bed + 1_800, newEndTs: wake - 1_800,
                                                    now: now)
        guard case .success(let done) = result else { return XCTFail("expected a correction, got \(result)") }
        XCTAssertEqual(done.edited, 1)
        XCTAssertTrue(done.requiresLocalRescore, "a computed row was touched, so the day must be scored again")
        let row = try await storedRow(store, computed, bed)
        XCTAssertEqual(row?.effectiveStartTs, bed + 1_800)
        XCTAssertEqual(row?.endTs, wake - 1_800)
    }

    /// Two rows can share a detected onset across the lanes, and only the block the night names says
    /// which one was drawn. The planner builds its clipped fragments without a device, so reading the
    /// lane off a fragment yields nil and the resolution falls back to "computed first" — which would
    /// rewrite a row the wearer never looked at while their night stayed as it was.
    func testTheBlockDecidesWhichLaneIsWritten() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: computed)
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: imported)
        let keys = [SleepNightEdit.BlockKey(deviceId: imported, startTs: bed)]

        let group = await SleepNightEdit.rows(store: store, ownerIds: ownerIds, keys: keys)
        XCTAssertEqual(group.first?.deviceId, imported,
                       "the row must come back stamped with the lane it was read from")

        let result = await SleepNightEdit.editTimes(store: store, ownerIds: ownerIds, group: group,
                                                    newStartTs: bed + 1_800, newEndTs: wake, now: now)
        guard case .success = result else { return XCTFail("expected a correction, got \(result)") }
        let touched = try await storedRow(store, imported, bed)
        let untouched = try await storedRow(store, computed, bed)
        XCTAssertEqual(touched?.effectiveStartTs, bed + 1_800, "the drawn row carries the correction")
        XCTAssertEqual(untouched?.effectiveStartTs, bed, "the other lane's row must not be touched")
    }

    /// The same for taking a night out: the key names the lane, and the other row stays.
    func testTheBlockDecidesWhichLaneIsRetired() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: computed)
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: imported)

        let retired = await SleepNightEdit.deleteNight(store: store, ownerIds: ownerIds,
                                                       detectedStartTs: bed, preferring: imported)
        XCTAssertEqual(retired?.ownerDeviceId, imported)
        let gone = try await storedRow(store, imported, bed)
        let kept = try await storedRow(store, computed, bed)
        XCTAssertNil(gone)
        XCTAssertNotNil(kept, "a row in the other lane is not the one the wearer deleted")
    }

    func testANightWithNoRowsIsRefusedByName() async throws {
        let store = try await WhoopStore.inMemory()
        let result = await SleepNightEdit.editTimes(store: store, ownerIds: ownerIds, group: [],
                                                    newStartTs: bed, newEndTs: wake, now: now)
        guard case .failure(let why) = result else { return XCTFail("an empty night cannot be corrected") }
        XCTAssertEqual(why, .noBlocks, "the one thing this must never do is look like success")
    }

    func testAWindowOverlappingNothingIsRefusedWithoutWriting() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: computed)
        let group = await SleepNightEdit.rows(
            store: store, ownerIds: ownerIds,
            keys: [SleepNightEdit.BlockKey(deviceId: computed, startTs: bed)])

        let far = bed + 48 * 3_600
        let result = await SleepNightEdit.editTimes(store: store, ownerIds: ownerIds, group: group,
                                                    newStartTs: far, newEndTs: far + 3_600,
                                                    now: far + 7_200)
        guard case .failure(let why) = result else { return XCTFail("a window off the night must be refused") }
        XCTAssertEqual(why, .noOverlap)
        let row = try await storedRow(store, computed, bed)
        XCTAssertEqual(row?.endTs, wake, "a refusal must leave the night exactly as it was")
    }

    func testAnImpossibleWindowIsRefused() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: computed)
        let group = await SleepNightEdit.rows(
            store: store, ownerIds: ownerIds,
            keys: [SleepNightEdit.BlockKey(deviceId: computed, startTs: bed)])

        let result = await SleepNightEdit.editTimes(store: store, ownerIds: ownerIds, group: group,
                                                    newStartTs: wake, newEndTs: bed, now: now)
        guard case .failure(let why) = result else { return XCTFail("an inverted window must be refused") }
        XCTAssertEqual(why, .invalidWindow)
    }

    /// Only a fragment whose window GREW is staged again: the planner can reshape stages that exist but
    /// cannot invent the ones for time the old window never covered, while a window that only narrows has
    /// nothing uncovered to stage.
    func testOnlyAGrownWindowIsStagedAgain() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: computed)
        let keys = [SleepNightEdit.BlockKey(deviceId: computed, startTs: bed)]

        var asked: [(Int, Int)] = []
        let narrower = await SleepNightEdit.rows(store: store, ownerIds: ownerIds, keys: keys)
        _ = await SleepNightEdit.editTimes(store: store, ownerIds: ownerIds, group: narrower,
                                           newStartTs: bed + 600, newEndTs: wake - 600, now: now,
                                           restage: { start, end in asked.append((start, end)); return nil })
        XCTAssertTrue(asked.isEmpty, "narrowing a night must not re-stage it")

        let grown = await SleepNightEdit.rows(store: store, ownerIds: ownerIds, keys: keys)
        _ = await SleepNightEdit.editTimes(store: store, ownerIds: ownerIds, group: grown,
                                           newStartTs: bed - 1_800, newEndTs: wake, now: now,
                                           restage: { start, end in asked.append((start, end)); return nil })
        XCTAssertEqual(asked.count, 1, "a night that grew is staged again from the raw streams")
    }

    func testRetiringANightAndPuttingItBack() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session(start: bed, end: wake)], deviceId: computed)

        guard let retired = await SleepNightEdit.deleteNight(store: store, ownerIds: ownerIds,
                                                             detectedStartTs: bed) else {
            return XCTFail("the night was there to retire")
        }
        XCTAssertEqual(retired.ownerDeviceId, computed, "it must be restored where it came from")
        XCTAssertTrue(retired.writesTombstone, "a detected night needs a marker or it comes straight back")
        var gone = try await storedRow(store, computed, bed)
        XCTAssertNil(gone)

        await SleepNightEdit.restore(store: store, rows: [retired])
        gone = try await storedRow(store, computed, bed)
        XCTAssertEqual(gone?.endTs, wake)
    }

    func testRetiringANightThatIsNotThereSaysSo() async throws {
        let store = try await WhoopStore.inMemory()
        let answer = await SleepNightEdit.deleteNight(store: store, ownerIds: ownerIds, detectedStartTs: bed)
        XCTAssertNil(answer, "nothing was deleted, so nothing may be reported as deleted")
    }
}
