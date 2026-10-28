import Foundation
import StrandAnalytics
import StrandCore
#if os(iOS)
import UIKit
#endif

/// The Apple apps' `AnalysisHost`: the settings the daily analysis reads come from the same switches the
/// Settings screens write, the strap log is `LiveState`'s (wired by `AppModel`), relaunch-surviving values
/// live in `UserDefaults` under their existing keys and types, and the background budget is
/// `RescoreBackgroundScheduler`'s.
@MainActor
final class AppAnalysisHost: AnalysisHost {
    /// Where strap-log lines go. `AppModel` wires it to `live.append(log:domain:)`; nil drops them, which
    /// keeps an engine built for a test or preview silent.
    var diagnosticSink: ((String, TestDomain?) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func analysisSettings() -> AnalysisSettings {
        AnalysisSettings(
            spo2CandidateDisplay: PuffinExperiment.spo2CandidateDisplayEnabled,
            sleepStagerV2: PuffinExperiment.experimentalSleepV2Enabled,
            motionAwareWake: PuffinExperiment.motionAwareWakeEnabled,
            deepHrvWindow: defaults.string(forKey: UnitPrefs.hrvWindowKey) == HrvWindow.deep.rawValue,
            dayCycleMode: DayCycleMode.persisted(defaults.string(forKey: DayCycleMode.storageKey)),
            rhythmAge: RhythmAgeFeature.isEnabled,
            healthspan: HealthspanFeature.isEnabled,
            hrvBaselineEpoch: Baselines.hrvBaselineEpoch(defaults),
            recoveryBaselineEpoch: Baselines.recoveryBaselineEpoch(defaults),
            traces: Set(TestDomain.allCases.filter { TestCentre.active($0) }))
    }

    func diagnostic(_ line: String, domain: TestDomain?) {
        diagnosticSink?(line, domain)
    }

    func storedBool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    func storedString(_ key: String) -> String? { defaults.string(forKey: key) }
    func store(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    func store(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    func store(_ value: Double, forKey key: String) { defaults.set(value, forKey: key) }

    func passWillStart() -> AnalysisPassTicket {
        let cpu = RescoreBackgroundScheduler.processCPUSeconds()
        let expiries = RescoreBackgroundScheduler.assertionExpiries
        let token = RescoreBackgroundScheduler.markRescoreOwed(passStarting: true)
        return AnalysisPassTicket(owedToken: token, cpuSecondsAtStart: cpu, assertionExpiriesAtStart: expiries)
    }

    func passDidFinish(_ ticket: AnalysisPassTicket, elapsedSeconds: Double) -> AnalysisPassReport {
        let settled = RescoreBackgroundScheduler.markRescoreCompleted(seconds: elapsedSeconds,
                                                                       owedToken: ticket.owedToken)
        let cpu = RescoreBackgroundScheduler.processCPUSeconds().flatMap { end in
            ticket.cpuSecondsAtStart.map { end - $0 }
        }
        let line = RescoreBackgroundScheduler.passCostLogLine(
            cpuSeconds: cpu, elapsedSeconds: elapsedSeconds,
            assertionExpiries: RescoreBackgroundScheduler.assertionExpiries - ticket.assertionExpiriesAtStart,
            backgroundedAtEnd: RescoreBackgroundScheduler.isBackgrounded)
        return AnalysisPassReport(settled: settled, costLine: line)
    }

    nonisolated func paceIfBackgrounded(since mark: inout UInt64) async {
        await RescoreBackgroundScheduler.paceIfBackgrounded(since: &mark)
    }

    func costReading() -> (cpuSeconds: Double?, batteryPercent: Int?) {
        var battery: Int?
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 { battery = Int((level * 100).rounded()) }
        #endif
        return (RescoreBackgroundScheduler.processCPUSeconds(), battery)
    }
}
