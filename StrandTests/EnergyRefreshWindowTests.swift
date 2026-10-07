import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The energy model's post-offload window and the Health-sync throttle.
@MainActor
final class EnergyRefreshWindowTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testAChangeTodayRefreshesOneDay() {
        let now = date(2026, 10, 7, 15)
        let start = Int(date(2026, 10, 7, 9).timeIntervalSince1970)
        XCTAssertEqual(Repository.energyRefreshDays(coveringStart: start, now: now, calendar: calendar), 1)
    }

    /// A UTC day start falls at 02:00 in Berlin; its local day is the same date and starts earlier, so
    /// the window covers every sample of that UTC day.
    func testAUTCDayStartCoversItsWholeLocalDay() {
        let now = date(2026, 10, 7, 15)
        let utcDayStart = Int(date(2026, 10, 5, 12).timeIntervalSince1970) / 86_400 * 86_400
        XCTAssertEqual(Repository.energyRefreshDays(coveringStart: utcDayStart, now: now, calendar: calendar), 3)
    }

    func testAnOldChangeIsCappedToTheFullWindow() {
        let now = date(2026, 10, 7, 15)
        let old = Int(date(2026, 1, 1).timeIntervalSince1970)
        XCTAssertEqual(Repository.energyRefreshDays(coveringStart: old, now: now, calendar: calendar),
                       Repository.energyRefreshMaxDays)
    }

    func testTheWindowIsAtLeastOneDay() {
        let now = date(2026, 10, 7, 15)
        let future = Int(date(2026, 10, 9).timeIntervalSince1970)
        XCTAssertEqual(Repository.energyRefreshDays(coveringStart: future, now: now, calendar: calendar), 1)
    }

    func testTheHealthSyncRefreshRunsAtMostHourly() {
        XCTAssertFalse(Repository.energyHealthRefreshIsRecent(last: nil, now: 10_000))
        XCTAssertTrue(Repository.energyHealthRefreshIsRecent(last: 10_000, now: 10_000 + 3_599))
        XCTAssertFalse(Repository.energyHealthRefreshIsRecent(last: 10_000, now: 10_000 + 3_600))
        XCTAssertFalse(Repository.energyHealthRefreshIsRecent(last: 10_000, now: 9_000),
                       "a clock moved backwards must not stop the refresh")
    }

    /// The equivalence the short window rests on, against two clones of a real store: after an offload,
    /// re-pricing only the changed days leaves exactly the rows a full 120-day refresh would. Skipped
    /// unless `TEST_RUNNER_NOOP_BENCH_DB` names a `whoop.sqlite`.
    func testTheShortPostOffloadWindowPricesLikeTheFullOne() async throws {
        guard let source = ProcessInfo.processInfo.environment["NOOP_BENCH_DB"], !source.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NOOP_BENCH_DB to a store copy to run this equivalence check")
        }
        let defaults = UserDefaults.standard
        let savedCursor = defaults.object(forKey: Repository.energyInputCursorKey)
        addTeardownBlock { defaults.set(savedCursor, forKey: Repository.energyInputCursorKey) }

        let (full, fullStore) = try await clonedRepository(from: source)
        let (short, shortStore) = try await clonedRepository(from: source)
        let profile = Repository.analyticsProfile(ProfileStore())

        // Both stores first get this build's full window, as the previous offload would have left them.
        let fullSettled = await full.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays, profile: profile)
        let shortSettled = await short.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays, profile: profile)
        XCTAssertTrue(fullSettled)
        XCTAssertTrue(shortSettled)
        defaults.set(try await shortStore.sensorWriteSeq(), forKey: Repository.energyInputCursorKey)

        // The same offload lands on both.
        let now = Int(Date().timeIntervalSince1970)
        let hr = (0..<600).map { HRSample(ts: now - 600 + $0, bpm: 80 + $0 % 23) }
        try await fullStore.insert(Streams(hr: hr), deviceId: "my-whoop")
        try await shortStore.insert(Streams(hr: hr), deviceId: "my-whoop")

        // Short first, full straight after: both price "now", and the seconds a day represents grow with
        // the wall clock, so the slow full refresh must not start half a minute after the short one.
        let shortStart = DispatchTime.now().uptimeNanoseconds
        await short.refreshWhoopEnergyModelAfterOffload(profile: profile)
        let shortSeconds = Double(DispatchTime.now().uptimeNanoseconds - shortStart) / 1e9
        let fullStart = DispatchTime.now().uptimeNanoseconds
        let fullRefreshed = await full.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays, profile: profile)
        XCTAssertTrue(fullRefreshed)
        let fullSeconds = Double(DispatchTime.now().uptimeNanoseconds - fullStart) / 1e9
        print(String(format: "BENCH energy after offload: full %.2f s, short %.2f s", fullSeconds, shortSeconds))

        let deviceId = full.deviceId
        let fullRows = try await fullStore.whoopDailyEnergy(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")
        let shortRows = try await shortStore.whoopDailyEnergy(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")
        XCTAssertFalse(fullRows.isEmpty)
        XCTAssertEqual(fullRows.count, shortRows.count)
        for (a, b) in zip(fullRows, shortRows) where a != b {
            let fields = zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children)
                .filter { "\($0.0.value)" != "\($0.1.value)" }
                .map { "\($0.0.label ?? "?"): \($0.0.value) vs \($0.1.value)" }
            XCTFail("day \(a.day) differs: " + fields.joined(separator: "; "))
        }
        for day in fullRows.suffix(3).map(\.day) {
            let a = try await fullStore.whoopEnergyBuckets(deviceId: deviceId, day: day)
            let b = try await shortStore.whoopEnergyBuckets(deviceId: deviceId, day: day)
            XCTAssertEqual(a, b, "buckets of \(day) differ")
        }
    }

    private func clonedRepository(from source: String) async throws -> (Repository, WhoopStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noop-energy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try FileManager.default.copyItem(atPath: source + suffix,
                                             toPath: dir.appendingPathComponent("whoop.sqlite" + suffix).path)
        }
        let store = try await WhoopStore(path: dir.appendingPathComponent("whoop.sqlite").path)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        return (repo, store)
    }
}
