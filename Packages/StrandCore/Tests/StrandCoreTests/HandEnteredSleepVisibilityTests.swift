import Foundation
import XCTest
import StrandAnalytics
import WhoopStore
@testable import StrandCore

/// What the Sleep screens browse: the imported blocks, the app's own re-staging where no import covers the
/// day, and ALWAYS what the wearer entered by hand (#49).
///
/// `addManualNap` writes into the computed namespace, and the layered read drops computed blocks for any
/// day an import covers — which is every day with a recorded night, so every day a nap would be added to.
/// The nap was stored, the day's figures moved with it, and the list that should show it did not.
final class HandEnteredSleepVisibilityTests: XCTestCase {

    private let day = 1_761_264_000            // 2026-10-24 00:00 UTC

    private func night(_ store: WhoopStore, deviceId: String, start: Int, end: Int) async throws {
        _ = try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 50, avgHrv: 60,
                                stagesJSON: #"[{"stage":"light","start":\#(start),"end":\#(end)}]"#)],
            deviceId: deviceId)
    }

    private func reader(_ store: WhoopStore) -> StoreReader {
        StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
    }

    /// The day the strap recorded a night is exactly the day a missed nap is added to, so the hand-entered
    /// block has to survive the day-level rule that drops the app's own re-staging.
    func testAHandEnteredNapSurvivesADayTheStrapAlreadyCovered() async throws {
        let store = try await WhoopStore.inMemory()
        try await night(store, deviceId: "my-whoop", start: day - 7 * 3_600, end: day + 1_800)
        let napStart = day + 14 * 3_600
        _ = try? await store.insertManualSleepSession(deviceId: "my-whoop-noop", startTs: napStart,
                                                      endTs: napStart + 1_800, efficiency: nil,
                                                      stagesJSON: #"[{"stage":"wake","start":\#(napStart),"end":\#(napStart + 1_800)}]"#)
        let blocks = await reader(store).allSleepSessions(from: day - 86_400, to: day + 86_400)
        XCTAssertEqual(blocks.map(\.startTs), [day - 7 * 3_600, napStart],
                       "the wearer's own entry is not the app's re-staging of an imported day")
        XCTAssertEqual(blocks.last?.userEdited, true)
    }

    /// The rule it must not break: the app's own re-staging of a day an import already covers stays out,
    /// so a night does not appear twice.
    func testAComputedRestagingOfAnImportedDayStaysOut() async throws {
        let store = try await WhoopStore.inMemory()
        try await night(store, deviceId: "my-whoop", start: day - 7 * 3_600, end: day + 1_800)
        try await night(store, deviceId: "my-whoop-noop", start: day - 6 * 3_600, end: day + 900)
        let blocks = await reader(store).allSleepSessions(from: day - 86_400, to: day + 86_400)
        XCTAssertEqual(blocks.map(\.startTs), [day - 7 * 3_600])
    }

    /// A CORRECTED computed night is `userEdited` too, and once an import covers the same hours the two are
    /// one night read twice: the import wins, as it does for an uncorrected one, or the day shows two nights.
    func testACorrectedComputedNightUnderAnImportStaysOut() async throws {
        let store = try await WhoopStore.inMemory()
        try await night(store, deviceId: "my-whoop-noop", start: day - 6 * 3_600, end: day + 900)
        _ = try await store.applySleepEdit(deviceId: "my-whoop-noop", detectedStartTs: day - 6 * 3_600,
                                           newStartTs: day - 6 * 3_600 - 1_800, newEndTs: day + 900)
        try await night(store, deviceId: "my-whoop", start: day - 7 * 3_600, end: day + 1_800)
        let blocks = await reader(store).allSleepSessions(from: day - 86_400, to: day + 86_400)
        XCTAssertEqual(blocks.map(\.startTs), [day - 7 * 3_600], "one night, the imported one")
    }

    /// And a day with no import at all still shows the computed night, hand-entered or not.
    func testADayWithNoImportStillShowsItsComputedNight() async throws {
        let store = try await WhoopStore.inMemory()
        try await night(store, deviceId: "my-whoop-noop", start: day - 7 * 3_600, end: day + 1_800)
        let blocks = await reader(store).allSleepSessions(from: day - 86_400, to: day + 86_400)
        XCTAssertEqual(blocks.map(\.startTs), [day - 7 * 3_600])
    }
}
