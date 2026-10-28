import XCTest
import WhoopStore
@testable import NoopCore

final class CoreUserInputsTests: XCTestCase {
    func testWireRowsPreserveNullsZeroAndNativeImportedSeparation() async throws {
        let store = try await WhoopStore.inMemory()
        let adopted = await CoreUserInputs.run("input.adopt", json: #"{"journal":[{"deviceId":"noop-journal","day":"2026-10-27","question":"Water?\n","answeredYes":false,"notes":"Keep","numericValue":0}],"hydration":[{"day":"2026-10-27","key":"hydration","value":200},{"day":"2026-10-27","key":"hydrationImported","value":500}]}"#, store: store)
        XCTAssertEqual(adopted, #"{"ok":true}"#)
        let cleared = await CoreUserInputs.run("input.journalDelete", json: #"{"source":"noop-journal","day":"2026-10-27","question":"Water?\n"}"#, store: store)
        XCTAssertEqual(cleared, #"{"ok":true}"#)
        _ = await CoreUserInputs.run("input.waterWrite", json: #"{"rows":[{"day":"2026-10-27","key":"hydrationImported","value":0}]}"#, store: store)
        let manual = try await store.metricSeries(deviceId: "hydration", key: "hydration", from: "2026-10-27", to: "2026-10-27")
        let imported = try await store.metricSeries(deviceId: "hydration", key: "hydrationImported", from: "2026-10-27", to: "2026-10-27")
        XCTAssertEqual(manual.first?.value, 200)
        XCTAssertEqual(imported.first?.value, 0)
        let json = await CoreUserInputs.run("input.journalRead", json: #"{"source":"noop-journal","from":"2026-10-27","to":"2026-10-27"}"#, store: store)
        XCTAssertEqual(json, "[]")
    }

    func testInvalidReplacementDoesNotClearTheExistingRange() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertJournal([.init(day: "2026-10-27", question: "Kept", answeredYes: true,
                                                notes: nil)], deviceId: "my-whoop")
        let result = await CoreUserInputs.run("input.journalReplace", json: #"{"source":"my-whoop","from":"2026-10-27","to":"2026-10-27","rows":[{"day":"2026-10-28","question":"Outside","answeredYes":true}]}"#, store: store)
        XCTAssertTrue(result.contains("error"))
        let rows = try await store.journalEntries(deviceId: "my-whoop", from: "2026-10-27", to: "2026-10-28")
        XCTAssertEqual(rows.map(\.question), ["Kept"])
    }
}
