import XCTest
import NoopCore

/// What the Android app gets from the core through the JNI entry points, checked without JNI.
final class BridgeTests: XCTestCase {
    func testTheRecipeIsTheCoresOwn() {
        XCTAssertGreaterThanOrEqual(Bridge.recipeVersion(), 31)
    }

    func testOpeningANewStoreRunsEveryMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let applied = Bridge.openStore(path: dir.appendingPathComponent("noop.sqlite").path)
        XCTAssertGreaterThan(applied, 70, "a fresh store runs the whole migration list")
        XCTAssertEqual(Bridge.openStore(path: dir.appendingPathComponent("noop.sqlite").path), applied,
                       "reopening applies nothing new")
    }

    func testAnUnopenablePathIsANegativeAnswerNotACrash() {
        XCTAssertLessThan(Bridge.openStore(path: "/nonexistent-dir/x/y/noop.sqlite"), 0)
    }

    func testAMainActorJobRuns() async {
        let before = Bridge.mainActorProbeRuns
        Bridge.scheduleMainActorProbe()
        for _ in 0..<100 where Bridge.mainActorProbeRuns == before {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Bridge.mainActorProbeRuns, before + 1)
    }

    func testMissingProtocolAssetRejectsResourceSetupBeforeASessionStarts() async {
        let answer = await CoreCall.run("core.setResources", #"{"dir":"/nonexistent-protocol-resources"}"#)
        XCTAssertEqual(answer, #"{"error":"protocolSchemaUnavailable"}"#)
    }

    func testSleepMethodExtrasOverrideLegacyABIWithoutLosingFallback() {
        var settings = CoreAnalysis.Settings.standard
        var profile = CoreAnalysis.Profile(age: 30, sex: "male", weightKg: 70, heightCm: 175, hrMaxOverride: 0)
        XCTAssertEqual(settings.analysisSettings.sleepStagerMethod, .v3)
        CoreAnalysis.applyExtras(#"{"sleepStagerMethod":"v2"}"#, to: &settings, profile: &profile)
        XCTAssertEqual(settings.analysisSettings.sleepStagerMethod, .v2)
        CoreAnalysis.applyExtras(#"{"sleepStagerMethod":"v1"}"#, to: &settings, profile: &profile)
        XCTAssertFalse(settings.analysisSettings.sleepStagerV2)
        CoreAnalysis.applyExtras(#"{"sleepStagerMethod":"invalid"}"#, to: &settings, profile: &profile)
        XCTAssertEqual(settings.analysisSettings.sleepStagerMethod, .v1)
    }

    /// An Android install that never touched its analysis choices scores like an untouched iPhone: Effort on
    /// heart-rate zones, the V2 sleep stager, no wake check, the whole-night HRV window, days from sleep onset
    /// (the Apple `AppAnalysisHost` defaults). The core used to hard-wire Banister and the V1 stager here.
    @MainActor
    func testTheStandardAnalysisSettingsAreTheAppleDefaults() {
        let s = CoreAnalysis.Settings.standard.analysisSettings
        XCTAssertEqual("\(s.effortMethod)", "edwards")
        XCTAssertTrue(s.sleepStagerV2)
        XCTAssertFalse(s.motionAwareWake)
        XCTAssertFalse(s.deepHrvWindow)
        XCTAssertEqual(s.dayCycleMode.rawValue, "sleep_onset")
        let chosen = CoreAnalysis.Settings(effortBanister: true, sleepStagerV2: false, motionAwareWake: true,
                                           deepHrvWindow: true, dayCycleMode: "midnight").analysisSettings
        XCTAssertEqual("\(chosen.effortMethod)", "banister")
        XCTAssertFalse(chosen.sleepStagerV2)
        XCTAssertTrue(chosen.motionAwareWake)
        XCTAssertTrue(chosen.deepHrvWindow)
        XCTAssertEqual(chosen.dayCycleMode.rawValue, "midnight")
    }
}
