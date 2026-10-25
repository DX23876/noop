import XCTest
import WhoopStore
import StrandCore
@testable import Strand

/// Re-analyses a copy of a real store and leaves the result for `Tools/compare_analysis_snapshots.py`
/// (Android plan B4). Run it once with the build before a restructuring and once with the build after it,
/// each writing its own output, then compare the two: every table must match.
///
/// Skipped unless both `NOOP_ANALYSIS_DB` (the store to copy) and `NOOP_ANALYSIS_OUT` (where the analysed
/// copy goes) are set; pass them to xcodebuild as `TEST_RUNNER_NOOP_ANALYSIS_DB=…` and
/// `TEST_RUNNER_NOOP_ANALYSIS_OUT=…`. `NOOP_ANALYSIS_DAYS` widens the window from the standard 21 days.
/// The source is copied first and never opened, and no personal data lives in the repository. The engine
/// reads the wall clock, so both runs belong on the same day; compare with
/// `--ignore-column '*.computedAtTs' --ignore-column '*.updatedAtTs'`, the times rows were written.
@MainActor
final class RealDataAnalysisSnapshotTests: XCTestCase {
    func testReanalyseAStoreCopy() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["NOOP_ANALYSIS_DB"], !source.isEmpty,
              let output = env["NOOP_ANALYSIS_OUT"], !output.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NOOP_ANALYSIS_DB and TEST_RUNNER_NOOP_ANALYSIS_OUT to run this")
        }
        BenchDefaultsGuard.preserve(in: self)
        let days = env["NOOP_ANALYSIS_DAYS"].flatMap(Int.init) ?? 21
        let files = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? files.removeItem(atPath: output + suffix)
            if files.fileExists(atPath: source + suffix) {
                try files.copyItem(atPath: source + suffix, toPath: output + suffix)
            }
        }
        let store = try await WhoopStore(path: output)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop")
        await engine.analyzeRecent(maxDays: days, force: true, allowDayReuse: false)
        // The pass ends with a dashboard refresh that schedules the readiness lanes in the background, and
        // those price cardio loads into the ledger. Run them to completion here, so both builds' copies hold
        // that work rather than whatever the background task finished before the process exited.
        await repo.refreshReadinessLoadContext()
    }

    /// Runs the recipe migration (the full rebuild) on a copy of a real store, as an install one recipe behind
    /// would on launch, and prints how long it took. Skipped unless `NOOP_REBUILD_DB` and `NOOP_REBUILD_OUT`
    /// are set (as `TEST_RUNNER_…`). Compare the output with the source for what the rebuild changed, and two
    /// outputs with each other for whether it is repeatable.
    func testRebuildAStoreCopy() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["NOOP_REBUILD_DB"], !source.isEmpty,
              let output = env["NOOP_REBUILD_OUT"], !output.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NOOP_REBUILD_DB and TEST_RUNNER_NOOP_REBUILD_OUT to run this")
        }
        BenchDefaultsGuard.preserve(in: self)
        let files = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? files.removeItem(atPath: output + suffix)
            if files.fileExists(atPath: source + suffix) {
                try files.copyItem(atPath: source + suffix, toPath: output + suffix)
            }
        }
        let store = try await WhoopStore(path: output)
        try await store.setCursor(AnalysisRecipe.cursor, AnalysisRecipe.currentVersion - 1)
        try await store.setCursor(AnalysisRecipe.rebuildCursor, 0)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop")
        let started = Date()
        let ok = await engine.prepareAnalysisRecipe()
        let elapsed = Date().timeIntervalSince(started)
        await repo.refreshReadinessLoadContext()
        print("rebuild: ok=\(ok) seconds=\(Int(elapsed))")
        XCTAssertTrue(ok)
        let recipe = try await store.cursor(AnalysisRecipe.cursor)
        XCTAssertEqual(recipe, AnalysisRecipe.currentVersion)
    }
}
