import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// "If scores look wrong" and Storage on Android (Settings parity, package 5): the numbers the pages read from the
/// core, and the rule that a repair never moves the analysis recipe.
final class CoreAnalysisMaintenanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AnalysisMaintenanceState.reset()
        UserDefaults.standard.removeObject(forKey: AnalysisMaintenanceState.lastRunKey)
    }

    override func tearDown() {
        AnalysisMaintenanceState.reset()
        UserDefaults.standard.removeObject(forKey: AnalysisMaintenanceState.lastRunKey)
        super.tearDown()
    }

    func testCoarseDurationsRoundUpLikeTheCard() {
        func c(_ s: TimeInterval) -> String {
            let v = CoreAnalysisMaintenance.Coarse(s)
            return "\(v.value) \(v.unit)"
        }
        XCTAssertEqual(c(0), "5 s")
        XCTAssertEqual(c(1), "5 s")
        XCTAssertEqual(c(11), "15 s")
        XCTAssertEqual(c(59), "60 s")
        XCTAssertEqual(c(61), "2 min")
        XCTAssertEqual(c(600), "10 min")
    }

    func testProgressHoldsBackTheEstimateAndNamesAStall() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let early = AnalysisProgress(stage: .scanning, completedDays: 2, reusedDays: 1, totalDays: 21,
                                     startedAt: t0, lastStepAt: t0)
        let early60 = CoreAnalysisMaintenance.ProgressWire(early, now: t0.addingTimeInterval(60))
        XCTAssertNil(early60.eta, "two days are too few for an estimate")
        XCTAssertEqual(early60.day, 3)
        XCTAssertEqual(early60.unchanged, 1)

        let later = AnalysisProgress(stage: .scanning, completedDays: 6, reusedDays: 0, totalDays: 21,
                                     startedAt: t0, lastStepAt: t0.addingTimeInterval(55))
        let wire = CoreAnalysisMaintenance.ProgressWire(later, now: t0.addingTimeInterval(60))
        XCTAssertEqual(wire.eta, CoreAnalysisMaintenance.Coarse(150), "60 s for 6 days leaves 15 days at 10 s")
        XCTAssertFalse(wire.stalled)
        XCTAssertEqual(wire.gap, CoreAnalysisMaintenance.Coarse(5))

        let quiet = CoreAnalysisMaintenance.ProgressWire(later, now: t0.addingTimeInterval(55 + 130))
        XCTAssertTrue(quiet.stalled)
        XCTAssertEqual(quiet.fraction, 6.0 / 21.0, accuracy: 1e-9)

        let finishing = AnalysisProgress(stage: .finishing, completedDays: 21, totalDays: 21, startedAt: t0,
                                         lastStepAt: t0)
        let done = CoreAnalysisMaintenance.ProgressWire(finishing, now: t0)
        XCTAssertEqual(done.stage, "finishing")
        XCTAssertEqual(done.fraction, 1)
        XCTAssertNil(done.eta)
    }

    func testARefreshThatEndsDuringAPassLeavesThePageOnThatPass() {
        AnalysisMaintenanceState.reset()
        XCTAssertTrue(AnalysisMaintenanceState.begin(.today))
        AnalysisMaintenanceState.passStarted()
        XCTAssertEqual(CoreAnalysisMaintenance.status().task, "today", "the refresh keeps its label")
        AnalysisMaintenanceState.finish()
        XCTAssertEqual(CoreAnalysisMaintenance.status().task, "background", "the pass still runs, so not idle")
        XCTAssertFalse(AnalysisMaintenanceState.begin(.today), "a second refresh waits for the pass")
        AnalysisMaintenanceState.finish(unless: .today)
        XCTAssertEqual(CoreAnalysisMaintenance.status().phase, "idle")
        AnalysisMaintenanceState.reset()
    }

    func testOnePassAtATimeAndOnlyARepairIsTheLastCompleted() {
        XCTAssertEqual(CoreAnalysisMaintenance.status().phase, "idle")
        XCTAssertNil(CoreAnalysisMaintenance.status().lastRun)

        XCTAssertTrue(AnalysisMaintenanceState.begin(.recent))
        XCTAssertFalse(AnalysisMaintenanceState.begin(.today), "buttons stay disabled while a pass runs")
        let working = CoreAnalysisMaintenance.status()
        XCTAssertEqual(working.phase, "working")
        XCTAssertEqual(working.task, "recent")
        AnalysisMaintenanceState.passStarted()
        XCTAssertEqual(CoreAnalysisMaintenance.status().task, "recent", "the pass keeps the repair's label")

        let end = Date(timeIntervalSince1970: 1_700_000_500)
        // The pass ends as `CoreAnalysis.run` ends it.
        AnalysisMaintenanceState.finish(now: end, unless: .today)
        let after = CoreAnalysisMaintenance.status()
        XCTAssertEqual(after.phase, "idle")
        XCTAssertEqual(after.lastRun, end.timeIntervalSince1970)
        XCTAssertEqual(UserDefaults.standard.double(forKey: AnalysisMaintenanceState.lastRunKey),
                       end.timeIntervalSince1970, "the moment survives a relaunch")

        // An ordinary pass after a sync is not a repair: it does not become "last completed".
        AnalysisMaintenanceState.reset()
        UserDefaults.standard.removeObject(forKey: AnalysisMaintenanceState.lastRunKey)
        AnalysisMaintenanceState.passStarted()
        XCTAssertEqual(CoreAnalysisMaintenance.status().task, "background")
        AnalysisMaintenanceState.finish(now: end, unless: .today)
        XCTAssertNil(CoreAnalysisMaintenance.status().lastRun)

        // A repair that failed names why and is not a completion either.
        XCTAssertTrue(AnalysisMaintenanceState.begin(.today))
        AnalysisMaintenanceState.finish(failure: "noCurrentDayActivity", now: end)
        let failed = CoreAnalysisMaintenance.status()
        XCTAssertEqual(failed.failure, "noCurrentDayActivity")
        XCTAssertNil(failed.lastRun)
    }

    func testTheOperationsAnswerAndRefuseBadRequests() async {
        let status = await CoreCall.run("analysis.maintenance", "{}")
        XCTAssertTrue(status.contains(#""phase":"idle""#), status)
        let bad = await CoreCall.run("analysis.reanalyzeRecent", "{}")
        XCTAssertEqual(bad, #"{"error":"invalid"}"#)
        let badToday = await CoreCall.run("analysis.refreshToday", "{}")
        XCTAssertEqual(badToday, #"{"error":"invalid"}"#)
        XCTAssertEqual(CoreAnalysisMaintenance.status().phase, "idle", "a refused request starts nothing")
    }

    func testTheRequestReadsTheSameChoicesAsTheDailyPass() throws {
        let args: [String: Any] = [
            "age": 41, "sex": "female", "weightKg": 63.5, "heightCm": 168.0, "hrMaxOverride": 188,
            "effortBanister": false, "sleepStagerV2": true, "motionAwareWake": true, "deepHrvWindow": true,
            "dayCycleMode": "midnight", "healthspan": true, "rhythmAge": false,
            "extras": #"{"waistCm":77,"historyRescore":true,"recoveryBaselineEpoch":1700000000}"#,
        ]
        let (profile, settings) = try XCTUnwrap(CoreAnalysisMaintenance.request(args))
        XCTAssertEqual(profile.age, 41)
        XCTAssertEqual(profile.hrMaxOverride, 188)
        XCTAssertEqual(profile.waistCm, 77)
        XCTAssertTrue(settings.motionAwareWake)
        XCTAssertTrue(settings.deepHrvWindow)
        XCTAssertEqual(settings.dayCycleMode, "midnight")
        XCTAssertEqual(settings.recoveryBaselineEpoch, 1_700_000_000)
        XCTAssertFalse(settings.historyRescore, "a repair is the 21 days, never the Lab switch's whole-history pass")
        XCTAssertNil(CoreAnalysisMaintenance.request(["age": 41]), "no sex, no request")
    }

    func testRepairsNeverMoveTheAnalysisRecipe() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await CoreDemo.seedIfEmpty(store: store, deviceId: "my-whoop")
        let before = try await AnalysisRecipe.storedVersion(store)
        let profile = CoreAnalysis.Profile(age: 40, sex: "male", weightKg: 80, heightCm: 180, hrMaxOverride: 0)

        _ = await CoreAnalysis.run(store: store, deviceId: "my-whoop", profile: profile, days: 3)
        XCTAssertEqual(CoreAnalysisMaintenance.status().phase, "idle", "a finished pass frees the page's buttons")
        XCTAssertNotNil(CoreAnalysisMaintenance.status().completedAt)

        _ = await CoreAnalysis.refreshToday(store: store, deviceId: "my-whoop", profile: profile, settings: .standard)
        let after = try await AnalysisRecipe.storedVersion(store)
        XCTAssertEqual(after, before, "manual repairs are diagnostics and leave the recipe cursor alone")
    }

    func testStorageReportsTheDatabaseFileAndCleanUpTruncatesTheLog() async throws {
        let path = NSTemporaryDirectory() + "storage-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let store = try await WhoopStore(path: path)
        _ = try await CoreDemo.seedIfEmpty(store: store, deviceId: "my-whoop")
        let report = await CoreStorage.report(store: store)
        let size = try XCTUnwrap(report.db)
        XCTAssertGreaterThan(size, 0)

        let cleaned = await CoreStorage.cleanUp(store: store)
        XCTAssertTrue(cleaned.checkpointed)
        let walPath = path + "-wal"
        let wal = (try? FileManager.default.attributesOfItem(atPath: walPath))?[.size] as? NSNumber
        XCTAssertEqual(wal?.int64Value ?? 0, 0, "the write-ahead log is folded back into the database file")
        let rows = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
        XCTAssertFalse(rows.isEmpty, "a clean-up never touches a row")

        let memory = try await WhoopStore.inMemory()
        let none = await CoreStorage.report(store: memory)
        XCTAssertNil(none.db, "a store with no file has no size")
    }
}
