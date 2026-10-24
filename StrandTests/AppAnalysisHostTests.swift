import XCTest
import StrandAnalytics
import StrandCore
@testable import Strand

/// The app host must keep every relaunch-surviving value under its existing key AND type: an install that
/// updates reads its watermark and heal flags back exactly as the engine wrote them before the host existed.
@MainActor
final class AppAnalysisHostTests: XCTestCase {
    /// A private defaults domain for one test, removed when the test ends.
    private func scratchDefaults() throws -> UserDefaults {
        let suite = "AppAnalysisHostTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testStoredValuesKeepTheirUserDefaultsTypes() throws {
        let defaults = try scratchDefaults()
        let host = AppAnalysisHost(defaults: defaults)
        host.store(true, forKey: "flag")
        XCTAssertTrue(defaults.bool(forKey: "flag"))
        XCTAssertTrue(host.storedBool("flag"))
        host.store("2026-10-01", forKey: "cursor")
        XCTAssertEqual(defaults.string(forKey: "cursor"), "2026-10-01")
        XCTAssertEqual(host.storedString("cursor"), "2026-10-01")
        host.store(nil, forKey: "cursor")
        XCTAssertNil(defaults.object(forKey: "cursor"))
        host.store(1_790_000_000.5, forKey: "lastRun")
        XCTAssertEqual(defaults.double(forKey: "lastRun"), 1_790_000_000.5)
    }

    func testSettingsReadTheSwitchesTheSettingsScreensWrite() throws {
        let defaults = try scratchDefaults()
        defaults.set(HrvWindow.deep.rawValue, forKey: UnitPrefs.hrvWindowKey)
        defaults.set(1_790_000_000.0, forKey: Baselines.hrvBaselineEpochKey)
        let settings = AppAnalysisHost(defaults: defaults).analysisSettings()
        XCTAssertTrue(settings.deepHrvWindow)
        XCTAssertEqual(settings.hrvBaselineEpoch, 1_790_000_000.0)
        XCTAssertEqual(settings.recoveryBaselineEpoch, 0)
        XCTAssertEqual(settings.dayCycleMode, DayCycleMode.persisted(nil))
    }

    func testDiagnosticsReachTheWiredSinkWithTheirDomain() throws {
        let defaults = try scratchDefaults()
        var lines: [(String, TestDomain?)] = []
        let host = AppAnalysisHost(defaults: defaults)
        host.diagnostic("dropped while unwired", domain: nil)
        host.diagnosticSink = { lines.append(($0, $1)) }
        host.diagnostic("hrv day=2026-10-01", domain: .hrv)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.0, "hrv day=2026-10-01")
        XCTAssertEqual(lines.first?.1, .hrv)
    }
}
