import XCTest
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore

/// #2438 step 0: each day's workout peak is the highest heart rate the band held for five consecutive samples
/// inside a workout, measured on the band's own trace whatever source the workout came from.
final class WorkoutPeakBankingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func workout(_ start: Int, minutes: Int, source: String = "manual") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: "Running", source: source,
                   durationS: Double(minutes * 60), energyKcal: nil, avgHr: nil, maxHr: 230, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testTheDaysPeakIsTheHeldValueInsideItsWorkouts() async throws {
        let store = try await WhoopStore(path: dir.appendingPathComponent("s.sqlite").path)
        let day = "2026-10-20"
        let start = try XCTUnwrap(DailyAnalysis.midnightForDayKey(day, offsetSec: 0)) + 10 * 3_600
        // 20 minutes at 150 with a held stretch at 188 and one single-sample spike to 205, then a held 199
        // OUTSIDE any workout that must not count.
        var hr = (0..<1_200).map { HRSample(ts: start + $0, bpm: 150) }
        for i in 600..<610 { hr[i] = HRSample(ts: start + i, bpm: 188) }
        hr[700] = HRSample(ts: start + 700, bpm: 205)
        hr += (0..<30).map { HRSample(ts: start + 3_600 + $0, bpm: 199) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "strap")

        try await DailyAnalysis.bankWorkoutPeaks(store: store, workouts: [workout(start, minutes: 20)],
                                                 strapId: "strap", computedId: "strap-noop",
                                                 fromDay: day, toDay: day, tzOffset: 0)

        let banked = try await store.metricSeries(deviceId: "strap-noop", key: DailyAnalysis.workoutPeakKey,
                                                  from: day, to: day)
        XCTAssertEqual(banked.map(\.value), [188])
    }

    func testAWorkoutOfAnotherSourceIsMeasuredOnTheBandsTrace() async throws {
        let store = try await WhoopStore(path: dir.appendingPathComponent("s.sqlite").path)
        let day = "2026-10-21"
        let start = try XCTUnwrap(DailyAnalysis.midnightForDayKey(day, offsetSec: 0)) + 8 * 3_600
        _ = try await store.insert(Streams(hr: (0..<600).map { HRSample(ts: start + $0, bpm: 176) }), deviceId: "strap")
        let imported = workout(start, minutes: 10, source: "apple_health")

        try await DailyAnalysis.bankWorkoutPeaks(store: store, workouts: [imported],
                                                 strapId: "strap", computedId: "strap-noop",
                                                 fromDay: day, toDay: day, tzOffset: 0)

        let banked = try await store.metricSeries(deviceId: "strap-noop", key: DailyAnalysis.workoutPeakKey,
                                                  from: day, to: day)
        XCTAssertEqual(banked.map(\.value), [176], "the imported row's own maxHr of 230 is never read")
    }

    /// A day worn on a strap that has since been replaced banks that strap's peak: the trace is read from the
    /// day's owner, not from the strap connected now (the WHOOP 5.0 to MG change of 2026-10-01).
    func testADayOfARetiredStrapBanksThatStrapsPeak() async throws {
        let store = try await WhoopStore(path: dir.appendingPathComponent("s.sqlite").path)
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        for id in ["old-five", "new-mg"] {
            try registry.add(PairedDevice(id: id, brand: "WHOOP", model: id == "old-five" ? "5.0" : "MG",
                                          sourceKind: .liveBLE, capabilities: [.hr], status: .paired,
                                          addedAt: 1, lastSeenAt: 1))
        }
        try registry.setActive("new-mg")
        try registry.archive("old-five")
        let day = "2026-09-20"
        let start = try XCTUnwrap(DailyAnalysis.midnightForDayKey(day, offsetSec: 0)) + 9 * 3_600
        _ = try await store.insert(Streams(hr: (0..<600).map { HRSample(ts: start + $0, bpm: 181) }),
                                   deviceId: "old-five")

        try await DailyAnalysis.bankWorkoutPeaks(store: store, workouts: [workout(start, minutes: 10)],
                                                 strapId: "my-whoop", computedId: "my-whoop-noop",
                                                 fromDay: day, toDay: day, tzOffset: 0)

        let banked = try await store.metricSeries(deviceId: "my-whoop-noop", key: DailyAnalysis.workoutPeakKey,
                                                  from: day, to: day)
        XCTAssertEqual(banked.map(\.value), [181])
    }
}
