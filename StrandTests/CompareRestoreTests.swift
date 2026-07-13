import XCTest
@testable import Strand

/// #358 parity: `CompareView.restoreSelection` is the twin of the Android `ComparePrefs.parseCompareSelection`
/// (`ComparePrefsTest.kt`) — restore a deliberate sub-minimum selection when every saved id still resolves,
/// but fall back to the defaults only when a catalog change dropped the saved ids below the minimum.
///
/// NOTE: `StrandTests` runs only under `xcodebuild test` on macOS (no CI leg — `app-build` is compile-only
/// of the app targets). The identical algorithm is exercised in CI on the Android side; this is the local
/// regression twin. Ids are the real `MetricDescriptor.id` form ("source:key").
final class CompareRestoreTests: XCTestCase {
    private let recovery = "my-whoop:recovery"
    private let hrv = "my-whoop:hrv"
    private let sleep = "my-whoop:sleep_performance"

    func testBlankYieldsNilSoTheCallerUsesDefaults() {
        XCTAssertNil(CompareView.restoreSelection("", minSelection: 2, maxSelection: 4))
        XCTAssertNil(CompareView.restoreSelection("   ,  ", minSelection: 2, maxSelection: 4))
    }

    func testRestoresSubMinimumWhenEveryIdResolves() {
        // A deliberate single-metric selection: every id resolves → restore it, don't reset to defaults.
        XCTAssertEqual(CompareView.restoreSelection(recovery, minSelection: 2, maxSelection: 4)?.map(\.id),
                       [recovery])
    }

    func testFallsBackWhenSurvivorsDropBelowMinimum() {
        // One real id + one lost to a catalog change → 1 survivor (< min) → nil (defaults).
        XCTAssertNil(CompareView.restoreSelection("\(recovery),gone:xyz", minSelection: 2, maxSelection: 4))
    }

    func testRestoresWhenAtLeastMinimumSurvives() {
        // Two resolve, one lost → 2 >= min → restore the survivors, in saved order.
        XCTAssertEqual(
            CompareView.restoreSelection("\(recovery),\(hrv),gone:xyz", minSelection: 2, maxSelection: 4)?.map(\.id),
            [recovery, hrv])
    }

    func testCapsAtMaxSelectionInOrder() {
        // Three valid ids, maxSelection 2 → keep the first two.
        XCTAssertEqual(
            CompareView.restoreSelection("\(recovery),\(hrv),\(sleep)", minSelection: 2, maxSelection: 2)?.map(\.id),
            [recovery, hrv])
    }

    func testDedupesRepeatedIds() {
        XCTAssertEqual(
            CompareView.restoreSelection("\(recovery),\(recovery),\(hrv)", minSelection: 2, maxSelection: 4)?.map(\.id),
            [recovery, hrv])
    }
}
