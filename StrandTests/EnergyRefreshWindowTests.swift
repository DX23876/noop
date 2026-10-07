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

    /// A re-derived day reaches the energy window with the evening before it, and the earliest one wins.
    func testRederivedDaysKeepTheEarliestStartWithADayOfLeadIn() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Repository.energyRederivedFromKey)
        defer { defaults.set(saved, forKey: Repository.energyRederivedFromKey) }
        defaults.removeObject(forKey: Repository.energyRederivedFromKey)
        let repo = Repository(deviceId: "test")
        repo.noteEnergyInputsRederived(dayStartTs: 10 * 86_400)
        repo.noteEnergyInputsRederived(dayStartTs: 12 * 86_400)
        XCTAssertEqual(defaults.object(forKey: Repository.energyRederivedFromKey) as? Int, 9 * 86_400)
        repo.noteEnergyInputsRederived(dayStartTs: 8 * 86_400)
        XCTAssertEqual(defaults.object(forKey: Repository.energyRederivedFromKey) as? Int, 7 * 86_400)
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
        BenchDefaultsGuard.preserve(in: self)
        let defaults = UserDefaults.standard

        let (full, fullStore) = try await clonedRepository(from: source)
        let (short, shortStore) = try await clonedRepository(from: source)
        let profile = Repository.analyticsProfile(ProfileStore())

        // Both stores first get this build's full window, as the previous offload would have left them.
        let fullSettled = await full.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays, profile: profile)
        let shortSettled = await short.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays, profile: profile)
        XCTAssertTrue(fullSettled)
        XCTAssertTrue(shortSettled)
        let cursorBeforeOffload = try await shortStore.sensorWriteSeq()
        defaults.set(cursorBeforeOffload, forKey: Repository.energyInputCursorKey)
        defaults.removeObject(forKey: Repository.energyRederivedFromKey)

        // The same offload lands on both.
        let now = Int(Date().timeIntervalSince1970)
        let hr = (0..<600).map { HRSample(ts: now - 600 + $0, bpm: 80 + $0 % 23) }
        try await fullStore.insert(Streams(hr: hr), deviceId: "my-whoop")
        try await shortStore.insert(Streams(hr: hr), deviceId: "my-whoop")

        // Short first, full straight after: both price "now", and the seconds a day represents grow with
        // the wall clock, so both must read it in the same second. If a second boundary falls between
        // them, the pair runs again from the pre-offload cursor (each refresh replaces its window).
        var shortSeconds = 0.0, fullSeconds = 0.0
        for attempt in 1...3 {
            defaults.set(cursorBeforeOffload, forKey: Repository.energyInputCursorKey)
            let shortSecond = Int(Date().timeIntervalSince1970)
            let shortStart = DispatchTime.now().uptimeNanoseconds
            await short.refreshWhoopEnergyModelAfterOffload(profile: profile)
            shortSeconds = Double(DispatchTime.now().uptimeNanoseconds - shortStart) / 1e9
            let fullSecond = Int(Date().timeIntervalSince1970)
            let fullStart = DispatchTime.now().uptimeNanoseconds
            let fullRefreshed = await full.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays,
                                                                   profile: profile)
            XCTAssertTrue(fullRefreshed)
            fullSeconds = Double(DispatchTime.now().uptimeNanoseconds - fullStart) / 1e9
            if shortSecond == fullSecond { break }
            if attempt == 3 { throw XCTSkip("three attempts straddled a second boundary") }
        }
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

    /// Times one full 120-day refresh on a clone and pins its output across code changes: with
    /// `TEST_RUNNER_NOOP_ENERGY_DUMP` it writes every stored daily row and the last 30 days of buckets
    /// to that file; with `TEST_RUNNER_NOOP_ENERGY_EXPECT` it compares against such a file. Skipped
    /// without `TEST_RUNNER_NOOP_BENCH_DB`. Used to prove an optimisation leaves the output byte-identical.
    func testTheFullRefreshCostAndOutput() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["NOOP_BENCH_DB"], !source.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NOOP_BENCH_DB to a store copy to run this benchmark")
        }
        BenchDefaultsGuard.preserve(in: self)
        let (repo, store) = try await clonedRepository(from: source)
        let profile = Repository.analyticsProfile(ProfileStore())
        // A fixed wall clock is not available to the model, so the day being priced right now is left out
        // of the comparison: its represented seconds grow with the clock.
        let today = Repository.localDayKey(Date())
        let start = DispatchTime.now().uptimeNanoseconds
        let ok = await repo.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays, profile: profile)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        XCTAssertTrue(ok)
        print(String(format: "BENCH energy full 120-day refresh %.2f s", seconds))

        let lines = try await storedEnergyLines(store: store, deviceId: repo.deviceId, before: today)

        // A second full refresh in the same process reads the memoised step movement of every unchanged day
        // and must leave exactly the same rows.
        let again = DispatchTime.now().uptimeNanoseconds
        let okAgain = await repo.refreshWhoopEnergyModel(days: Repository.energyRefreshMaxDays, profile: profile)
        print(String(format: "BENCH energy full refresh again (memoised steps) %.2f s",
                     Double(DispatchTime.now().uptimeNanoseconds - again) / 1e9))
        XCTAssertTrue(okAgain)
        let linesAgain = try await storedEnergyLines(store: store, deviceId: repo.deviceId, before: today)
        XCTAssertEqual(lines, linesAgain, "a memoised refresh must leave identical rows")
        let text = lines.joined(separator: "\n")
        if let dump = env["NOOP_ENERGY_DUMP"], !dump.isEmpty {
            try text.write(toFile: dump, atomically: true, encoding: .utf8)
            print("BENCH energy output written: \(lines.count) lines")
        }
        if let expect = env["NOOP_ENERGY_EXPECT"], !expect.isEmpty {
            let expected = try String(contentsOfFile: expect, encoding: .utf8).components(separatedBy: "\n")
            XCTAssertEqual(expected.count, lines.count, "line count")
            let firstDiff = zip(expected, lines).enumerated().first { $0.element.0 != $0.element.1 }
            if let firstDiff {
                XCTFail("first difference at line \(firstDiff.offset):\nexpected \(firstDiff.element.0)\nactual   \(firstDiff.element.1)")
            } else {
                print("BENCH energy output identical: \(lines.count) lines")
            }
        }
    }

    private func storedEnergyLines(store: WhoopStore, deviceId: String, before today: String) async throws -> [String] {
        let rows = try await store.whoopDailyEnergy(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")
            .filter { $0.day < today }
        var lines = rows.map { "\($0)" }
        for day in rows.suffix(30).map(\.day) {
            lines += try await store.whoopEnergyBuckets(deviceId: deviceId, day: day).map { "\($0)" }
        }
        return lines
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
