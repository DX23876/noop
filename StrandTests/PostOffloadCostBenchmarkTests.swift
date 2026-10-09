import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Measures what a completed strap offload costs after it lands, step by step, against a copy of a real
/// store. Skipped unless `NOOP_BENCH_DB` names a `whoop.sqlite` (pass it to xcodebuild as
/// `TEST_RUNNER_NOOP_BENCH_DB=/path/whoop.sqlite`); the file is cloned first, so the original is never
/// opened. No personal data lives in the repository: the store path comes from the environment.
///
/// Each simulated offload banks three minutes of heart rate ending now under the active strap, then runs
/// the steps `AppModel.refreshAfterCompletedBackfill` runs, timing each. The engine reads the wall clock,
/// so "today" is the real day; a store that ends earlier simply has no data for it. That is the daytime
/// case the cost matters for: new samples after a finished night.
@MainActor
final class PostOffloadCostBenchmarkTests: XCTestCase {

    private static let offloads = 3
    private static let deviceId = "my-whoop"

    func testWhatEachPostOffloadStepCosts() async throws {
        guard let source = ProcessInfo.processInfo.environment["NOOP_BENCH_DB"], !source.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NOOP_BENCH_DB to a store copy to run this benchmark")
        }
        BenchDefaultsGuard.preserve(in: self)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noop-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try FileManager.default.copyItem(atPath: source + suffix,
                                             toPath: dir.appendingPathComponent("whoop.sqlite" + suffix).path)
        }
        let store = try await WhoopStore(path: dir.appendingPathComponent("whoop.sqlite").path)
        let repo = Repository(deviceId: Self.deviceId)
        repo.setStoreForTesting(store)
        let profile = ProfileStore()
        let engine = IntelligenceEngine(repo: repo, profile: profile, deviceId: Self.deviceId)
        var passLines: [String] = []
        engine.diagnosticSink = { line, _ in
            if line.hasPrefix("re-score:") || line.contains("postLoop") { passLines.append(line) }
        }

        // Settle once so the stored day fingerprints match this test host's profile.
        let settle = try await timed { await engine.analyzeRecent(force: true, allowDayReuse: true) }
        print(String(format: "BENCH settle pass %.1f s", settle))

        for round in 1...Self.offloads {
            let now = Int(Date().timeIntervalSince1970)
            let hr = (0..<180).map { HRSample(ts: now - 180 + $0, bpm: 72 + $0 % 7) }
            try await store.insert(Streams(hr: hr), deviceId: Self.deviceId)
            passLines.removeAll()

            let activity = try await timed { _ = await engine.refreshCurrentDayActivity() }
            let rescore = try await timed {
                await engine.analyzeRecent(skipIfUnchanged: true, allowDayReuse: true, reason: .rawMutation)
            }
            let plans = try await timed { await PlanReconciliationCoordinator.reconcile(repo: repo) }
            let goals = try await timed { await GoalTrackingStore.shared.refresh(repo: repo) }
            let energy = try await timed {
                _ = await repo.refreshWhoopEnergyModel(days: 120, profile: Repository.analyticsProfile(profile))
            }
            print(String(format: "BENCH offload %d: activity %.2f s, rescore %.2f s, plans %.2f s, goals %.2f s, energy %.2f s",
                         round, activity, rescore, plans, goals, energy))
            for line in passLines { print("BENCH   " + String(line.prefix(220))) }
        }
    }

    private func timed(_ body: () async throws -> Void) async throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}
