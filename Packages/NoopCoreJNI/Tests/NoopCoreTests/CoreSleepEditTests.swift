import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// The night names its own blocks, and the bridge edits exactly those.
///
/// Android drew a night the core had assembled from both sleep lanes and then looked its rows up again
/// in the imported lane alone. On a wearer whose recent nights NOOP scores itself that found nothing, and
/// every layer below swallowed the fact (2026-11-21). These tests pin the two halves of the repair: the
/// night carries the keys of the rows it was built from, and the operation writes those rows.
final class CoreSleepEditTests: XCTestCase {
    private let imported = "my-whoop"
    private let computed = "my-whoop-noop"
    private let bed = 1_700_000_000
    private var wake: Int { bed + 8 * 3_600 }

    private func store(computedNight: Bool = true) async throws -> (WhoopStore, StoreReader) {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: imported, registeredWhoopIds: [])
        let session = CachedSleepSession(startTs: bed, endTs: wake, efficiency: 0.9, restingHr: 52,
                                         avgHrv: 60,
                                         stagesJSON: "[{\"start\":\(bed),\"end\":\(wake),\"stage\":\"light\"}]")
        _ = try await store.upsertSleepSessions([session], deviceId: computedNight ? computed : imported)
        return (store, reader)
    }

    func testANightNamesTheRowsItWasBuiltFrom() async throws {
        let (_, reader) = try await store()
        let nights = await CoreRead.nights(from: bed - 86_400, to: wake + 86_400, reader: reader,
                                           offsetSec: 0)
        XCTAssertEqual(nights.count, 1)
        let blocks = nights[0].blocks
        XCTAssertEqual(blocks.count, 1, "a night with no blocks cannot be corrected by anyone")
        XCTAssertEqual(blocks.first?.startTs, bed)
        XCTAssertEqual(blocks.first?.deviceId, computed,
                       "the lane matters: an edit that guesses it writes the wrong row or none")
    }

    func testCorrectingTheNightTheBridgeWasGiven() async throws {
        let (store, reader) = try await store()
        let nights = await CoreRead.nights(from: bed - 86_400, to: wake + 86_400, reader: reader,
                                           offsetSec: 0)
        let blocks = nights[0].blocks.map { ["deviceId": $0.deviceId as Any, "startTs": $0.startTs] }
        let answer = await CoreSleepEdit.run("sleep.editTimes",
                                             ["blocks": blocks, "start": bed + 1_800, "end": wake,
                                              "now": wake + 3_600, "deviceId": imported],
                                             store: store, reader: reader)
        let json = try XCTUnwrap(answer)
        XCTAssertTrue(json.contains("\"outcome\":\"saved\""), json)
        let row = try await store.sleepSessions(deviceId: computed, from: bed - 10, to: bed + 10, limit: 4)
            .first { $0.startTs == bed }
        XCTAssertEqual(row?.effectiveStartTs, bed + 1_800)
    }

    func testAnEmptyBlockListIsRefusedByName() async throws {
        let (store, reader) = try await store()
        let answer = await CoreSleepEdit.run("sleep.editTimes",
                                             ["blocks": [[String: Any]](), "start": bed, "end": wake],
                                             store: store, reader: reader)
        let json = try XCTUnwrap(answer)
        XCTAssertTrue(json.contains("\"ok\":false"), json)
        XCTAssertTrue(json.contains("\"outcome\":\"noBlocks\""), json)
    }

    func testRetiringTheNightAndTakingThatBack() async throws {
        let (store, reader) = try await store()
        let nights = await CoreRead.nights(from: bed - 86_400, to: wake + 86_400, reader: reader,
                                           offsetSec: 0)
        let blocks = nights[0].blocks.map { ["deviceId": $0.deviceId as Any, "startTs": $0.startTs] }
        let deletedAnswer = await CoreSleepEdit.run("sleep.deleteNight", ["blocks": blocks],
                                                    store: store, reader: reader)
        let deleted = try XCTUnwrap(deletedAnswer)
        XCTAssertTrue(deleted.contains("\"outcome\":\"saved\""), deleted)
        var rows = try await store.sleepSessions(deviceId: computed, from: bed - 10, to: bed + 10, limit: 4)
        XCTAssertTrue(rows.isEmpty)

        // The token the answer carries is how the undo strip asks for the same rows back.
        let token = try XCTUnwrap(deleted.split(separator: "\"undoToken\":\"").last?
            .split(separator: "\"").first.map(String.init))
        let undoneAnswer = await CoreSleepEdit.run("sleep.undoRetired", ["token": token],
                                                   store: store, reader: reader)
        let undone = try XCTUnwrap(undoneAnswer)
        XCTAssertTrue(undone.contains("\"outcome\":\"saved\""), undone)
        rows = try await store.sleepSessions(deviceId: computed, from: bed - 10, to: bed + 10, limit: 4)
        XCTAssertEqual(rows.first?.endTs, wake)
    }

    /// A night the bridge was told to delete must leave the other lane's row with the same onset alone.
    func testDeletingTakesTheLaneTheBlockNames() async throws {
        let (store, reader) = try await store()
        let session = CachedSleepSession(startTs: bed, endTs: wake, efficiency: 0.9, restingHr: 52,
                                         avgHrv: 60,
                                         stagesJSON: "[{\"start\":\(bed),\"end\":\(wake),\"stage\":\"light\"}]")
        _ = try await store.upsertSleepSessions([session], deviceId: imported)
        let blocks = [["deviceId": imported as Any, "startTs": bed]]
        let raw = await CoreSleepEdit.run("sleep.deleteNight", ["blocks": blocks],
                                          store: store, reader: reader)
        let answer = try XCTUnwrap(raw)
        XCTAssertTrue(answer.contains("\"outcome\":\"saved\""), answer)
        let gone = try await store.sleepSessions(deviceId: imported, from: bed - 10, to: bed + 10, limit: 4)
        let kept = try await store.sleepSessions(deviceId: computed, from: bed - 10, to: bed + 10, limit: 4)
        XCTAssertTrue(gone.isEmpty)
        XCTAssertEqual(kept.count, 1, "the computed row shares the onset and was not the one deleted")
    }

    /// A block whose row has already gone is not a failure, but it is not a whole deletion either.
    func testAPartlyDeletedNightSaysSo() async throws {
        let (store, reader) = try await store()
        let blocks: [[String: Any]] = [["deviceId": computed as Any, "startTs": bed],
                                       ["deviceId": computed as Any, "startTs": bed - 7_200]]
        let raw = await CoreSleepEdit.run("sleep.deleteNight", ["blocks": blocks],
                                          store: store, reader: reader)
        let answer = try XCTUnwrap(raw)
        XCTAssertTrue(answer.contains("\"outcome\":\"partial\""), answer)
        XCTAssertTrue(answer.contains("\"ok\":true"), answer)
    }

    func testAnUnknownUndoTokenIsNotReportedAsDone() async throws {
        let (store, reader) = try await store()
        let raw = await CoreSleepEdit.run("sleep.undoRetired", ["token": "nothing"],
                                          store: store, reader: reader)
        let answer = try XCTUnwrap(raw)
        XCTAssertTrue(answer.contains("\"outcome\":\"notFound\""), answer)
    }
}
