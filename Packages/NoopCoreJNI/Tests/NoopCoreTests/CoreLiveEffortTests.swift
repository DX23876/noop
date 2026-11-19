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

    /// One yardstick for one day: the live read resolves HRmax through the pass's own resolver
    /// (`CoreAnalysis.passHRmax`), so an override reaches the live score and the fallback is the formula
    /// the stored day was scored with — not a second copy of it reading a store nothing writes.
    func testTheHRmaxYardstickIsThePassesOwn() {
        XCTAssertEqual(CoreAnalysis.passHRmax(overrideBpm: 193, age: 40).bpm, 193)
        XCTAssertEqual(CoreAnalysis.passHRmax(overrideBpm: 0, age: 40).bpm,
                       MaxHeartRate.resolve(overrideBpm: 0, age: 40, measured: nil).bpm)
    }

    /// Without a cycle to go by the window is the logical day's own, as it always was.
    func testTheWindowStartsAtTheLogicalDayWithoutACycle() {
        let now = Date()
        let (from, to) = LiveEffortScore.window(now: now, mode: .sleepOnset, cycle: nil)
        XCTAssertLessThanOrEqual(from, to)
        XCTAssertEqual(to, Int(now.timeIntervalSince1970))
        let dayStart = Calendar.current.startOfDay(for: LogicalDay.date(now))
        XCTAssertEqual(from, Int(dayStart.timeIntervalSince1970))
        // Workout rows reach a day back, so a session begun before the day started still counts.
        XCTAssertEqual(LiveEffortScore.workoutWindow(forWindow: (from, to)).from, from - 86_400)
    }

    /// With a cycle, the window begins where the wearer fell asleep — which is where the nightly pass
    /// begins the day. The tester of 2026-11-19 slept 04:41 to 13:19 and found Effort at 47 on waking:
    /// his waking hours between midnight and 04:41 belong to the cycle before this one, and a midnight
    /// window counted them again here.
    func testTheWindowStartsAtTheSleepOnsetOfTheCycle() {
        let now = Date()
        let nowTs = Int(now.timeIntervalSince1970)
        let onset = nowTs - 9 * 3_600
        let cycle = CycleDayWindow.Cycle(onset: onset, wakeDay: "2026-11-19")
        let (from, to) = LiveEffortScore.window(now: now, mode: .sleepOnset, cycle: cycle)
        XCTAssertEqual(from, onset)
        XCTAssertEqual(to, nowTs)
        // Midnight mode is the conventional civil day and keeps the logical-day start it always had.
        let midnight = LiveEffortScore.window(now: now, mode: .midnight, cycle: cycle)
        XCTAssertEqual(midnight.from,
                       Int(Calendar.current.startOfDay(for: LogicalDay.date(now)).timeIntervalSince1970))
    }

    /// Worn heart rate scores, and the answer never falls below what the stored row already earned.
    func testAWornDayScoresAndNeverFallsBelowTheStoredRow() async throws {
        let store = try await WhoopStore.inMemory()
        let (from, to) = LiveEffortScore.window(now: Date(), mode: .sleepOnset, cycle: nil)
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
