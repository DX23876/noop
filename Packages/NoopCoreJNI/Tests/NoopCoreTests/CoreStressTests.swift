import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore
@testable import NoopCore

/// Today's daytime stress for Android (parity plan 1.3): the core reads the store's union and scores it exactly as
/// `DaytimeStress.analyze` scores the same samples, the way Apple's `StressDayCurve` does.
@MainActor
final class CoreStressTests: XCTestCase {
    func testTheCoreScoresTodayAsTheAnalyticsDo() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(15 * 3_600)
        let start = Int(calendar.startOfDay(for: now).timeIntervalSince1970) + 8 * 3_600
        // Seven waking hours at one sample a second, as the strap records, the heart rate climbing through the day.
        let hr = (0..<(7 * 3_600)).map { HRSample(ts: start + $0, bpm: 60 + $0 / 1_200) }
        // One beat a second with a little alternation, shortening as the rate climbs, so each hour has an RMSSD.
        let rr = (0..<(7 * 3_600)).map { i in
            RRInterval(ts: start + i, rrMs: 60_000 / (60 + i / 1_200) + (i % 2 == 0 ? 15 : -15))
        }
        try await store.insert(Streams(hr: hr, rr: rr), deviceId: "my-whoop")

        let empty = await CoreStress.fingerprint(reader: reader, now: now.addingTimeInterval(-12 * 3_600))
        let fingerprint = await CoreStress.fingerprint(reader: reader, now: now)
        XCTAssertNotEqual(empty, fingerprint)

        let output = await CoreStress.day(reader: reader, personalBaseline: false, now: now)
        let stored = await reader.rrIntervals(from: start, to: Int(now.timeIntervalSince1970), limit: 200_000)
        let expected = DaytimeStress.analyze(hr: hr, rr: stored, gravity: [],
                                             tzOffsetSeconds: TimeZone.current.secondsFromGMT(for: now),
                                             mode: .dayRelative, includeTimeline: true)
        XCTAssertFalse(output.usesPersonalBaseline)
        XCTAssertEqual(output.hours.map(\.level), expected.hours.map(\.level))
        XCTAssertEqual(output.timeline.count, expected.timeline.count)
        XCTAssertEqual(output.dayMean, expected.dayMean)
        XCTAssertEqual(output.highStressMinutes, expected.highStressMinutes)
        XCTAssertFalse(output.hours.compactMap(\.level).isEmpty)

        // The answer Kotlin parses (`CoreStressTest`), pinned by shape; NOOP_UPDATE_TRAINING_FIXTURES=1 rewrites it.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/stress/day.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let pinned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(pinned.keys), Set(fresh.keys))
    }

    func testTooLittleHeartRateIsAnEmptyDay() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let output = await CoreStress.day(reader: reader, personalBaseline: true)
        XCTAssertTrue(output.hours.isEmpty)
        XCTAssertNil(output.dayMean)
        XCTAssertFalse(output.usesPersonalBaseline)
    }
}
