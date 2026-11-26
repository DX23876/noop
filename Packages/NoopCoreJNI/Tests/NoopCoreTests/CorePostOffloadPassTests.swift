import XCTest
@testable import NoopCore
import StrandCore
import WhoopProtocol
import WhoopStore

/// The pass the Android client asks for after a completed offload runs as Apple's `AppModel` runs that one: skipped
/// when no sensor row moved, and otherwise deriving only the days whose raw inputs moved. Until 2026-11-26 every
/// Android pass derived the whole window again, about 70 times a day, which testers saw as the app topping the
/// phone's battery list.
@MainActor
final class CorePostOffloadPassTests: XCTestCase {
    private let profile = CoreAnalysis.Profile(age: 40, sex: "male", weightKg: 80, heightCm: 180, hrMaxOverride: 0)

    /// One reading a minute from 08:00 to 20:00 local time on the day `daysAgo` before today.
    private func daytimeHeartRate(daysAgo: Int) -> [HRSample] {
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
        let start = Int(midnight.timeIntervalSince1970) + 8 * 3_600
        return (0..<(12 * 60)).map { HRSample(ts: start + $0 * 60, bpm: 70 + ($0 % 30)) }
    }

    /// One reading a minute over the hour that just ended.
    private func lastHourHeartRate() -> [HRSample] {
        let start = Int(Date().timeIntervalSince1970) - 3_600
        return (0..<60).map { HRSample(ts: start + $0 * 60, bpm: 70 + ($0 % 30)) }
    }

    private func settings(afterOffload: Bool) -> CoreAnalysis.Settings {
        var settings = CoreAnalysis.Settings.standard
        settings.afterOffload = afterOffload
        return settings
    }

    func testAPassAfterAnOffloadSkipsWithoutNewDataAndKeepsTheDaysThatDidNotMove() async throws {
        let store = try await WhoopStore.inMemory()
        for daysAgo in 1...3 {
            try await store.insert(Streams(hr: daytimeHeartRate(daysAgo: daysAgo)), deviceId: "my-whoop")
        }
        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile,
                                   settings: settings(afterOffload: false), days: 5)
        let full = CoreAnalysis.PassLog.drain()
        XCTAssertTrue(full.contains { $0.hasPrefix("re-score: cost cpu=") }, "every pass reports what it cost: \(full)")

        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile,
                                   settings: settings(afterOffload: true), days: 5)
        let unchanged = CoreAnalysis.PassLog.drain()
        XCTAssertTrue(unchanged.contains { $0.contains("newData=no") && $0.contains("skipped") },
                      "an offload that banked nothing new scores nothing: \(unchanged)")

        // The hour before now, never the day's 08:00 to 20:00: run shortly after midnight, those readings lay in
        // the future, and a full pass and a post-offload pass bound "today" differently for samples not yet taken.
        try await store.insert(Streams(hr: lastHourHeartRate()), deviceId: "my-whoop")
        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile,
                                   settings: settings(afterOffload: true), days: 5)
        let summary = try XCTUnwrap(CoreAnalysis.PassLog.drain().first { $0.hasPrefix("reuse summary:") })
        let reused = try XCTUnwrap(Int(summary.split(separator: " ")
            .first { $0.hasPrefix("reused=") }?.dropFirst("reused=".count) ?? ""))
        XCTAssertGreaterThanOrEqual(reused, 2, "the days the offload did not touch are kept: \(summary)")

        // Keeping a day must not change a score: a full pass over the same store writes the same rows.
        func scores() async throws -> [String] {
            try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "2000-01-01", to: "2100-01-01").map {
                "\($0.day) strain=\(String(describing: $0.strain)) recovery=\(String(describing: $0.recovery)) "
                    + "sleep=\(String(describing: $0.totalSleepMin)) rhr=\(String(describing: $0.restingHr))"
            }
        }
        let afterReuse = try await scores()
        XCTAssertFalse(afterReuse.isEmpty)
        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile,
                                   settings: settings(afterOffload: false), days: 5)
        _ = CoreAnalysis.PassLog.drain()
        let afterFull = try await scores()
        XCTAssertEqual(afterReuse, afterFull, "the post-offload pass stores what a full pass stores")
    }

    /// Apple keeps the watermark in UserDefaults; the core kept it for the process only, so the first offload after
    /// a restart scored again even when it had banked nothing new.
    func testTheWatermarkOutlivesTheProcess() async throws {
        let suite = "core-bookkeeping-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        CoreAnalysis.bookkeepingDefaults = defaults
        defer { CoreAnalysis.bookkeepingDefaults = nil; defaults.removePersistentDomain(forName: suite) }
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: daytimeHeartRate(daysAgo: 1)), deviceId: "my-whoop")
        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile,
                                   settings: settings(afterOffload: false), days: 3)
        XCTAssertNotNil(defaults.string(forKey: DailyAnalysis.analyzeWatermarkKey))

        CoreAnalysis.forgetProcessBookkeepingForTesting()
        _ = CoreAnalysis.PassLog.drain()
        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile,
                                   settings: settings(afterOffload: true), days: 3)
        let lines = CoreAnalysis.PassLog.drain()
        XCTAssertTrue(lines.contains { $0.contains("newData=no") && $0.contains("skipped") },
                      "after a restart an offload with nothing new still skips: \(lines)")
    }

    /// Apple's background rules (`RescoreBackgroundPolicy`): a post-offload pass in the background starts at most
    /// every 30 minutes, the one put off runs when the app comes to the front, and nothing else is ever put off.
    func testABackgroundOffloadPassIsSpacedAndRunsInFront() {
        CoreAnalysis.Background.resetForTesting(background: true)
        defer { CoreAnalysis.Background.resetForTesting(background: true) }
        _ = CoreAnalysis.PassLog.drain()
        func request(afterOffload: Bool) -> AnalysisRuns.Request {
            .init(profile: profile, settings: settings(afterOffload: afterOffload), deviceId: "a")
        }
        XCTAssertTrue(CoreAnalysis.Background.admit(request(afterOffload: true)), "the first pass runs")
        let started = Date()
        CoreAnalysis.Background.passWillWork(now: started)

        XCTAssertFalse(CoreAnalysis.Background.admit(request(afterOffload: true), now: started.addingTimeInterval(600)),
                       "ten minutes later, in the background, the next one waits")
        XCTAssertTrue(CoreAnalysis.PassLog.drain().contains { $0.hasPrefix("re-score: deferred (post-offload)") })
        XCTAssertTrue(CoreAnalysis.Background.admit(request(afterOffload: false), now: started.addingTimeInterval(600)),
                      "a setting or a repair is never put off")
        XCTAssertNil(CoreAnalysis.Background.set(background: true))
        XCTAssertNotNil(CoreAnalysis.Background.set(background: false), "in front, the put-off pass is handed back")
        XCTAssertNil(CoreAnalysis.Background.set(background: false), "once")
        XCTAssertTrue(CoreAnalysis.Background.admit(request(afterOffload: true), now: started.addingTimeInterval(700)),
                      "in front nothing waits")

        _ = CoreAnalysis.Background.set(background: true)
        XCTAssertFalse(CoreAnalysis.Background.admit(request(afterOffload: true), now: started.addingTimeInterval(900)))
        XCTAssertTrue(CoreAnalysis.Background.admit(request(afterOffload: true),
                                                    now: started.addingTimeInterval(RescoreBackgroundPolicy.backgroundSpacingSeconds + 60)),
                      "past the spacing the next offload runs and settles the put-off one")
        XCTAssertNil(CoreAnalysis.Background.set(background: false), "nothing is owed any more")
    }

    func testOnlyThePostOffloadPassReusesDays() throws {
        var settings = CoreAnalysis.Settings.standard
        var profile = profile
        CoreAnalysis.applyExtras(#"{"afterOffload":true}"#, to: &settings, profile: &profile)
        XCTAssertTrue(settings.afterOffload)

        let args: [String: Any] = ["age": 40, "sex": "male", "weightKg": 80.0, "heightCm": 180.0, "hrMaxOverride": 0,
                                   "extras": #"{"afterOffload":true}"#]
        let (_, repair) = try XCTUnwrap(CoreAnalysisMaintenance.request(args))
        XCTAssertFalse(repair.afterOffload, "a repair derives every day of the window again")
    }

    func testAFullPassStaysFullWhenAPostOffloadPassJoinsIt() async {
        final class Held: @unchecked Sendable { var value = true }
        let holding = Held()
        var ran: [Bool] = []
        let runs = AnalysisRuns(hold: { holding.value }, pollStep: .milliseconds(5)) { ran.append($0.settings.afterOffload) }
        func joined(_ first: Bool, _ second: Bool) async -> [Bool] {
            ran = []; holding.value = true
            runs.request(.init(profile: profile, settings: settings(afterOffload: first), deviceId: "a"))
            runs.request(.init(profile: profile, settings: settings(afterOffload: second), deviceId: "a"))
            holding.value = false
            await runs.settled()
            return ran
        }
        let fullFirst = await joined(false, true)
        XCTAssertEqual(fullFirst, [false], "a post-offload request joining a full one leaves it full")
        let fullSecond = await joined(true, false)
        XCTAssertEqual(fullSecond, [false], "and the other way round")
        let bothAfterOffload = await joined(true, true)
        XCTAssertEqual(bothAfterOffload, [true], "two post-offload requests stay a post-offload pass")
    }

    func testTheCostLineReadsLikeTheApplesOne() {
        XCTAssertEqual(CoreAnalysis.passCostLine(cpuSeconds: 12.34, elapsedSeconds: 20),
                       "re-score: cost cpu=12.3s elapsed=20.0s cpuShare=62%")
        XCTAssertEqual(CoreAnalysis.passCostLine(cpuSeconds: nil, elapsedSeconds: 3),
                       "re-score: cost cpu=n/a elapsed=3.0s cpuShare=n/a")
        XCTAssertNotNil(CoreAnalysis.processCPUSeconds())
    }

    func testTheLogKeepsTheNewestLinesUntilCollected() {
        _ = CoreAnalysis.PassLog.drain()
        for i in 0..<(CoreAnalysis.PassLog.capacity + 5) { CoreAnalysis.PassLog.append("line \(i)") }
        let lines = CoreAnalysis.PassLog.drain()
        XCTAssertEqual(lines.count, CoreAnalysis.PassLog.capacity)
        XCTAssertEqual(lines.first, "line 5")
        XCTAssertEqual(CoreAnalysis.PassLog.drain(), [], "collected lines are gone")
    }
}
