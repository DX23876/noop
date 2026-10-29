import XCTest
import StrandAnalytics
import StrandCore

final class AnalysisSettingsTests: XCTestCase {
    private func settings(hrvEpoch: Double = 0, recoveryEpoch: Double = 0,
                          traces: Set<TestDomain> = []) -> AnalysisSettings {
        AnalysisSettings(effortMethod: .edwards, spo2CandidateDisplay: false, sleepStagerV2: false,
                         motionAwareWake: false, deepHrvWindow: false, dayCycleMode: .persisted(nil),
                         rhythmAge: false, healthspan: false, hrvBaselineEpoch: hrvEpoch,
                         recoveryBaselineEpoch: recoveryEpoch, traces: traces)
    }

    func testSleepMethodSurvivesCapturedSettingsAndHealSignatures() {
        var captured = settings()
        XCTAssertEqual(captured.sleepStagerMethod, .v1)
        captured.sleepStagerMethod = .v3
        XCTAssertTrue(captured.sleepStagerV2)
        let v2 = EditedSleepHeal.Staging(method: .v2, motionAwareWake: false)
        let v3 = EditedSleepHeal.Staging(method: .v3, motionAwareWake: false)
        XCTAssertNotEqual(v2.signature, v3.signature)
        XCTAssertTrue(v3.sleepV2)
    }

    func testOnlyTheCapturedDomainsTrace() {
        let s = settings(traces: [.sleep, .universal])
        XCTAssertTrue(s.traces(.sleep))
        XCTAssertTrue(s.traces(.universal))
        XCTAssertFalse(s.traces(.hrv))
    }

    /// The pass's stress cut and the Stress screen's (`Cut.current`) resolve the same epochs one way.
    func testTheStressCutComesFromTheTwoEpochs() throws {
        XCTAssertEqual(settings().stressCut, .none)
        let hrv = 1_790_000_000.0
        let recovery = 1_790_500_000.0
        let cut = settings(hrvEpoch: hrv, recoveryEpoch: recovery).stressCut
        XCTAssertEqual(cut.hrvFirstNight, Baselines.firstNightAfterRecalibration(epoch: hrv))
        XCTAssertEqual(cut.rhrFirstNight, Baselines.firstNightAfterRecalibration(epoch: recovery))

        let suite = "AnalysisSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(hrv, forKey: Baselines.hrvBaselineEpochKey)
        defaults.set(recovery, forKey: Baselines.recoveryBaselineEpochKey)
        XCTAssertEqual(StressMath.Cut.current(defaults), cut)
    }
}
