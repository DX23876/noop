import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore
@testable import NoopCore

/// The nap read Android's Sleep card uses (#49).
///
/// The card asks for the stretch between the night's wake and the end of that day, which is the honest
/// question — and the read has to answer it over whole days anyway, because a block is a nap only beside
/// the night it is not. Asked over the narrow window alone, the nap WAS the day's only block, so it became
/// the day's main night and the card reported no nap for a nap that was in the store.
@MainActor
final class CoreNapReadTests: XCTestCase {

    private func reader(_ store: WhoopStore) -> StoreReader {
        StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
    }

    /// 2026-10-24 00:00 UTC, in the device's own zone so the day grouping matches the read.
    private var midnight: Int {
        Int(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_761_264_000)).timeIntervalSince1970)
    }

    func testANapIsFoundThroughAWindowThatStartsAtTheNightsWake() async throws {
        let store = try await WhoopStore.inMemory()
        let nightStart = midnight - 7 * 3_600, nightEnd = midnight + 1_800
        _ = try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: nightStart, endTs: nightEnd, efficiency: 0.9, restingHr: 50,
                                avgHrv: 60,
                                stagesJSON: #"[{"stage":"light","start":\#(nightStart),"end":\#(nightEnd)}]"#)],
            deviceId: "my-whoop")
        let napStart = midnight + 14 * 3_600
        _ = try? await store.insertManualSleepSession(
            deviceId: "my-whoop-noop", startTs: napStart, endTs: napStart + 1_800, efficiency: nil,
            stagesJSON: #"[{"stage":"wake","start":\#(napStart),"end":\#(napStart + 1_800)}]"#)

        let naps = await CoreRead.naps(from: nightEnd, to: midnight + 86_400, reader: reader(store))
        XCTAssertEqual(naps.map(\.startTs), [napStart],
                       "the night is outside the asked window, but the grouping still needs it")
    }

    /// The look-back is for grouping, not for the answer: a nap on the day BEFORE the window is not in it.
    func testTheLookBackDoesNotLeakTheDayBefore() async throws {
        let store = try await WhoopStore.inMemory()
        let yesterdayNapStart = midnight - 10 * 3_600
        _ = try? await store.insertManualSleepSession(
            deviceId: "my-whoop-noop", startTs: yesterdayNapStart, endTs: yesterdayNapStart + 1_800,
            efficiency: nil, stagesJSON: nil)
        let nightStart = midnight - 6 * 3_600, nightEnd = midnight + 1_800
        _ = try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: nightStart, endTs: nightEnd, efficiency: 0.9, restingHr: 50,
                                avgHrv: 60,
                                stagesJSON: #"[{"stage":"light","start":\#(nightStart),"end":\#(nightEnd)}]"#)],
            deviceId: "my-whoop")
        let naps = await CoreRead.naps(from: nightEnd, to: midnight + 86_400, reader: reader(store))
        XCTAssertEqual(naps, [])
    }
}
