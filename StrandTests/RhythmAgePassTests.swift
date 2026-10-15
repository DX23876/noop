import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The daily rhythm pass: once per local day it scores the seven days before that day from the strap's own
/// `@41` and stores the readout, so the screens read finished numbers instead of a week of per-second rows.
final class RhythmAgePassTests: XCTestCase {

    private let strap = "my-whoop"
    private let computed = "my-whoop-noop"
    private let day = "2026-10-16"
    private var dayStart: Int { IntelligenceEngine.midnightForDayKey(day, offsetSec: 0)! }

    private func makeStore() async throws -> WhoopStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-pass-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        return try await WhoopStore(path: path)
    }

    /// `days` days of per-second `@41` ending at the start of `day`, following a day-night cosine.
    private func insertMotion(_ store: WhoopStore, days: Int, hoursPerDay: Int = 24) async throws {
        for d in 0..<days {
            var streams = Streams.empty
            let start = dayStart - (days - d) * 86_400
            for s in 0..<(hoursPerDay * 3600) {
                let mg = 40 + 35 * cos(2 * Double.pi * (Double(s) / 3600 - 14) / 24)
                streams.gravity.append(GravitySample(ts: start + s, x: 0, y: 0, z: 1, dynAccel: mg / 1000))
            }
            try await store.insert(streams, deviceId: strap)
        }
    }

    private func value(_ store: WhoopStore, _ key: String) async throws -> Double? {
        try await store.metricSeries(deviceId: computed, key: key, from: day, to: day).first?.value
    }

    func testAWornWeekStoresTheReadingOnTheDay() async throws {
        let store = try await makeStore()
        try await insertMotion(store, days: 7)
        await IntelligenceEngine.runRhythmAgePass(store: store, strapId: strap, computedId: computed,
                                                  age: 40, sex: "", day: day, tzOffset: 0)
        let advance = try await value(store, IntelligenceEngine.rhythmAdvanceKey)
        XCTAssertNotNil(advance)
        let peak = try await value(store, IntelligenceEngine.rhythmPeakKey)
        XCTAssertEqual(peak ?? 0, 14, accuracy: 0.3)
        let hours = try await value(store, IntelligenceEngine.rhythmHoursKey)
        XCTAssertEqual(hours ?? 0, 168, accuracy: 0.1)
        let morning = try await value(store, IntelligenceEngine.rhythmHourKey(3))
        let afternoon = try await value(store, IntelligenceEngine.rhythmHourKey(14))
        XCTAssertGreaterThan(afternoon ?? 0, morning ?? .infinity, "the stored day must follow the worn day")
    }

    func testTooFewHoursStoreOnlyTheHoursCollectedSoFar() async throws {
        let store = try await makeStore()
        try await insertMotion(store, days: 2)
        await IntelligenceEngine.runRhythmAgePass(store: store, strapId: strap, computedId: computed,
                                                  age: 40, sex: "", day: day, tzOffset: 0)
        let hours = try await value(store, IntelligenceEngine.rhythmHoursKey)
        XCTAssertEqual(hours ?? 0, 48, accuracy: 0.1)
        let advance = try await value(store, IntelligenceEngine.rhythmAdvanceKey)
        XCTAssertNil(advance)
    }

    func testNoMotionStoresNothing() async throws {
        let store = try await makeStore()
        await IntelligenceEngine.runRhythmAgePass(store: store, strapId: strap, computedId: computed,
                                                  age: 40, sex: "", day: day, tzOffset: 0)
        let hours = try await value(store, IntelligenceEngine.rhythmHoursKey)
        XCTAssertNil(hours)
    }

    func testTheDayIsScoredOnlyOnce() async throws {
        let store = try await makeStore()
        try await insertMotion(store, days: 2)
        await IntelligenceEngine.runRhythmAgePass(store: store, strapId: strap, computedId: computed,
                                                  age: 40, sex: "", day: day, tzOffset: 0)
        try await insertMotion(store, days: 7)
        await IntelligenceEngine.runRhythmAgePass(store: store, strapId: strap, computedId: computed,
                                                  age: 40, sex: "", day: day, tzOffset: 0)
        let hours = try await value(store, IntelligenceEngine.rhythmHoursKey)
        XCTAssertEqual(hours ?? 0, 48, accuracy: 0.1, "a second pass on the same day must not re-read the week")
    }

    func testForcingTheDayScoresItAgain() async throws {
        let store = try await makeStore()
        try await insertMotion(store, days: 2)
        await IntelligenceEngine.runRhythmAgePass(store: store, strapId: strap, computedId: computed,
                                                  age: 40, sex: "", day: day, tzOffset: 0)
        try await insertMotion(store, days: 7)
        await IntelligenceEngine.runRhythmAgePass(store: store, strapId: strap, computedId: computed,
                                                  age: 40, sex: "", day: day, tzOffset: 0, force: true)
        let advance = try await value(store, IntelligenceEngine.rhythmAdvanceKey)
        XCTAssertNotNil(advance, "switching the feature on must not wait for tomorrow")
    }
}
