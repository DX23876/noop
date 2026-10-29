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

    /// An Android install that never touched its analysis choices scores like an untouched iPhone: the V2
    /// sleep stager, no wake check, the whole-night HRV window, days from sleep onset
    /// (the Apple `AppAnalysisHost` defaults). The core used to hard-wire Banister and the V1 stager here.
    @MainActor
    func testTheStandardAnalysisSettingsAreTheAppleDefaults() {
        let s = CoreAnalysis.Settings.standard.analysisSettings
        XCTAssertTrue(s.sleepStagerV2)
        XCTAssertFalse(s.motionAwareWake)
        XCTAssertFalse(s.deepHrvWindow)
        XCTAssertEqual(s.dayCycleMode.rawValue, "sleep_onset")
        let chosen = CoreAnalysis.Settings(effortBanister: true, sleepStagerV2: false, motionAwareWake: true,
                                           deepHrvWindow: true, dayCycleMode: "midnight").analysisSettings
        XCTAssertFalse(chosen.sleepStagerV2)
        XCTAssertTrue(chosen.motionAwareWake)
        XCTAssertTrue(chosen.deepHrvWindow)
        XCTAssertEqual(chosen.dayCycleMode.rawValue, "midnight")
    }
}
