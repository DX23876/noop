import XCTest
import WhoopStore
@testable import Strand

/// Re-analyses a copy of a real store and leaves the result for `Tools/compare_analysis_snapshots.py`
/// (Android plan B4). Run it once with the build before a restructuring and once with the build after it,
/// each writing its own output, then compare the two: every table must match.
///
/// Skipped unless both `NOOP_ANALYSIS_DB` (the store to copy) and `NOOP_ANALYSIS_OUT` (where the analysed
/// copy goes) are set; pass them to xcodebuild as `TEST_RUNNER_NOOP_ANALYSIS_DB=…` and
/// `TEST_RUNNER_NOOP_ANALYSIS_OUT=…`. `NOOP_ANALYSIS_DAYS` widens the window from the standard 21 days.
/// The source is copied first and never opened, and no personal data lives in the repository. The engine
/// reads the wall clock, so both runs belong on the same day.
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
    }
}
