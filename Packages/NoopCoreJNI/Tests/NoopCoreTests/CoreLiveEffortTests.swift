import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore
@testable import NoopCore

/// Today's Effort as a Today screen shows it. The Apple screens have re-scored today's raw heart rate
/// since #402 because the stored row only moves when the nightly pass runs; the Android Forge screen read
/// the stored row raw, so the same wearer saw two different Efforts depending only on which Today was
/// open (#41). These hold the shared rules the two now share.
@MainActor
final class CoreLiveEffortTests: XCTestCase {

    private func reader(_ store: WhoopStore) -> StoreReader {
        StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
    }

    /// A day with no heart rate cannot be scored, so the stored row stands: the screens fall back to it
    /// rather than to a fabricated number.
    func testWithoutHeartRateTheStoredRowStands() async throws {
        let store = try await WhoopStore.inMemory()
        let effort = await CoreRead.liveEffort(reader: reader(store), hrMaxOverride: 0, age: 40,
                                               restingHr: 55, storedEffort: 31.0)
        XCTAssertEqual(effort, 31.0)
    }

    func testWithNeitherThereIsNothingToShow() async throws {
        let store = try await WhoopStore.inMemory()
        let effort = await CoreRead.liveEffort(reader: reader(store), hrMaxOverride: 0, age: 40,
                                               restingHr: nil, storedEffort: nil)
        XCTAssertNil(effort)
    }

    /// The window is the logical day's own, so an hour recorded yesterday evening is not today's Effort.
    func testTheWindowStartsAtTheLogicalDay() {
        let now = Date()
        let (from, to) = LiveEffortScore.window(now: now)
        XCTAssertLessThanOrEqual(from, to)
        XCTAssertEqual(to, Int(now.timeIntervalSince1970))
        let dayStart = Calendar.current.startOfDay(for: LogicalDay.date(now))
        XCTAssertEqual(from, Int(dayStart.timeIntervalSince1970))
        // Workout rows reach a day back, so a session begun before midnight still counts inside the window.
        XCTAssertEqual(LiveEffortScore.workoutWindow(now: now).from, from - 86_400)
    }

    /// Worn heart rate scores, and the answer never falls below what the stored row already earned.
    func testAWornDayScoresAndNeverFallsBelowTheStoredRow() async throws {
        let store = try await WhoopStore.inMemory()
        let (from, to) = LiveEffortScore.window(now: Date())
        guard to - from > 3_600 else {
            throw XCTSkip("run before 01:00 local: the logical day is too short to lay down an hour of heart rate")
        }
        let samples = (0..<3_600).map { HRSample(ts: from + $0, bpm: 150) }
        try await store.insert(Streams(hr: samples), deviceId: "my-whoop")
        let live = await CoreRead.liveEffort(reader: reader(store), hrMaxOverride: 190, age: 40,
                                             restingHr: 55, storedEffort: nil)
        let scored = try XCTUnwrap(live)
        XCTAssertGreaterThan(scored, 0)
        let floored = await CoreRead.liveEffort(reader: reader(store), hrMaxOverride: 190, age: 40,
                                                restingHr: 55, storedEffort: scored + 10)
        XCTAssertEqual(floored, scored + 10, "the stored row is a floor, never lowered by a live refinement")
    }
}
