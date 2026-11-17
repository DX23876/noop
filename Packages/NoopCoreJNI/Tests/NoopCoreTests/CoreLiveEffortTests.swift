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

    /// With no cycle in force the window is the logical day's own, so an hour recorded yesterday evening
    /// is not today's Effort.
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

    /// The window follows the DAY CYCLE when one is in force, because that is the span the pass scored the
    /// stored row over. The two meet in `effectiveEffort`, which takes the larger, so a live figure over
    /// the calendar day and a stored figure over the cycle are two answers to one question — and the
    /// sleep-onset cycle is the default, not an exotic setting (#41).
    func testTheWindowFollowsTheCycleWhenOneIsInForce() {
        let now = Date()
        let onset = Int(now.timeIntervalSince1970) - 9 * 3_600
        let start = LiveEffortScore.cycleStart(onsetMarkers: [Double(onset)], now: now, offsetSec: 0)
        XCTAssertEqual(start, onset)
        XCTAssertEqual(LiveEffortScore.window(now: now, cycleStart: start).from, onset)
        XCTAssertEqual(LiveEffortScore.workoutWindow(now: now, cycleStart: start).from, onset - 86_400)
    }

    /// Markers are read, not trusted: a marker in the future is not a boundary that has happened, and the
    /// newest of the usable ones is the one in force.
    func testTheNewestUsableMarkerWins() {
        let now = Date()
        let nowTs = Int(now.timeIntervalSince1970)
        let start = LiveEffortScore.cycleStart(
            onsetMarkers: [Double(nowTs - 20 * 3_600), Double(nowTs - 6 * 3_600), Double(nowTs + 3_600), 0, .nan],
            now: now, offsetSec: 0)
        XCTAssertEqual(start, nowTs - 6 * 3_600)
        XCTAssertNil(LiveEffortScore.cycleStart(onsetMarkers: [], now: now, offsetSec: 0))
    }

    /// Past the resolver's cap an open cycle is not stretched further: the pass synthesizes a midnight
    /// boundary there, and the live window has to be the same one rather than a span of two days.
    func testAnOverlongCycleFallsBackWhereThePassDoes() {
        let now = Date()
        let nowTs = Int(now.timeIntervalSince1970)
        let stale = nowTs - DayCycleResolver.absoluteMaxOpenSeconds - 3_600
        let start = try? XCTUnwrap(LiveEffortScore.cycleStart(onsetMarkers: [Double(stale)], now: now,
                                                              offsetSec: 0))
        XCTAssertEqual(start, DayCycleResolver.fallbackMidnight(after: stale, offsetSec: 0))
    }

    /// End to end: an hour of heart rate inside the cycle but BEFORE the logical day's midnight counts
    /// towards today's Effort, because the stored row counts it. Without the marker the same hour is
    /// yesterday's and the day cannot be scored at all.
    func testHeartRateInsideTheCycleButBeforeMidnightCounts() async throws {
        let store = try await WhoopStore.inMemory()
        // 10:00 local on a fixed day, with the cycle's onset at 23:00 the evening before.
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_761_264_000))
        let now = midnight.addingTimeInterval(10 * 3_600)
        let onset = Int(midnight.timeIntervalSince1970) - 3_600
        let samples = (0..<3_600).map { HRSample(ts: onset + 60 + $0, bpm: 150) }
        try await store.insert(Streams(hr: samples), deviceId: "my-whoop")
        let withoutCycle = await CoreRead.liveEffort(reader: reader(store), hrMaxOverride: 190, age: 40,
                                                     restingHr: 55, storedEffort: nil, now: now)
        XCTAssertNil(withoutCycle, "before the fix that hour was simply outside today's window")
        _ = try await store.upsertMetricSeries(
            [MetricPoint(day: StoreReader.localDayKey(now), key: DayCycleIntelligenceIntegration.onsetKey,
                         value: Double(onset))],
            deviceId: "my-whoop-noop")
        let withCycle = await CoreRead.liveEffort(reader: reader(store), hrMaxOverride: 190, age: 40,
                                                  restingHr: 55, storedEffort: nil, now: now)
        XCTAssertGreaterThan(try XCTUnwrap(withCycle), 0)
    }
}
