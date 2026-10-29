import Foundation
import StrandAnalytics

/// Everything the daily analysis reads from the wearer's settings, captured once when a pass starts.
///
/// The pass used to read these one by one from `UserDefaults`, the experiment switches and the Test Centre
/// while it ran. A snapshot keeps one pass on one set of choices and lets each platform supply them from its
/// own settings store (Android plan B3 step 3).
public struct AnalysisSettings: Equatable, Sendable {
    /// TRIMP method behind Effort.
    public var effortMethod: StrainScorer.Method
    /// Whether the experimental SpO2 candidate is shown, which decides whether it is computed.
    public var spo2CandidateDisplay: Bool
    /// Complete sleep pipeline, captured once for this pass.
    public var sleepStagerMethod: SleepStager.Method
    /// Compatibility for callers that selected only the phase engine.
    public var sleepStagerV2: Bool {
        get { sleepStagerMethod.usesV2Stages }
        set { sleepStagerMethod = newValue ? .v2 : .v1 }
    }
    /// Experimental motion-aware wake detection.
    public var motionAwareWake: Bool
    /// HRV read over the deep-sleep window instead of the whole night.
    public var deepHrvWindow: Bool
    /// How a day's activity is split between wake days.
    public var dayCycleMode: DayCycleMode
    /// The daily rhythm (Rhythm Age) pass runs.
    public var rhythmAge: Bool
    /// The AgeLess (healthspan) pass runs.
    public var healthspan: Bool
    /// Manual "Recalibrate baseline" epoch for HRV, in epoch seconds; 0 when never recalibrated.
    public var hrvBaselineEpoch: Double
    /// Manual "Recalibrate baseline" epoch for the wider recovery baselines, in epoch seconds; 0 when never.
    public var recoveryBaselineEpoch: Double
    /// Test Centre domains whose trace lines the pass builds.
    public var traces: Set<TestDomain>

    public init(effortMethod: StrainScorer.Method, spo2CandidateDisplay: Bool, sleepStagerV2: Bool,
                motionAwareWake: Bool, deepHrvWindow: Bool, dayCycleMode: DayCycleMode, rhythmAge: Bool,
                healthspan: Bool, hrvBaselineEpoch: Double, recoveryBaselineEpoch: Double,
                traces: Set<TestDomain>, sleepStagerMethod: SleepStager.Method? = nil) {
        self.effortMethod = effortMethod
        self.spo2CandidateDisplay = spo2CandidateDisplay
        self.sleepStagerMethod = sleepStagerMethod ?? (sleepStagerV2 ? .v2 : .v1)
        self.motionAwareWake = motionAwareWake
        self.deepHrvWindow = deepHrvWindow
        self.dayCycleMode = dayCycleMode
        self.rhythmAge = rhythmAge
        self.healthspan = healthspan
        self.hrvBaselineEpoch = hrvBaselineEpoch
        self.recoveryBaselineEpoch = recoveryBaselineEpoch
        self.traces = traces
    }

    /// Whether the pass builds the trace lines of `domain`.
    public func traces(_ domain: TestDomain) -> Bool { traces.contains(domain) }

    /// The stress proxy's recalibration cut for these epochs.
    public var stressCut: StressMath.Cut {
        StressMath.Cut(hrvBaselineEpoch: hrvBaselineEpoch, recoveryBaselineEpoch: recoveryBaselineEpoch)
    }
}

/// What one pass captured when it started, handed back when it finishes.
public struct AnalysisPassTicket: Sendable {
    /// Identifies the re-score debt this pass may settle; a later request carries another token.
    public let owedToken: String?
    /// Process CPU seconds when the pass started, when the platform can measure them.
    public let cpuSecondsAtStart: Double?
    /// Background-time expiries counted before the pass started.
    public let assertionExpiriesAtStart: Int

    public init(owedToken: String?, cpuSecondsAtStart: Double?, assertionExpiriesAtStart: Int) {
        self.owedToken = owedToken
        self.cpuSecondsAtStart = cpuSecondsAtStart
        self.assertionExpiriesAtStart = assertionExpiriesAtStart
    }
}

/// How a finished pass left the host's re-score bookkeeping.
public struct AnalysisPassReport: Sendable {
    /// False when a newer re-score request arrived during the pass and stays owed.
    public let settled: Bool
    /// The strap-log line with the pass's cost.
    public let costLine: String

    public init(settled: Bool, costLine: String) {
        self.settled = settled
        self.costLine = costLine
    }
}

/// What the daily analysis needs from the platform it runs on: settings, the strap log, small values that
/// must survive a relaunch, and the background-time budget. iOS implements it over `UserDefaults`, the Test
/// Centre and its background-task scheduler; Android implements it over its own equivalents.
public protocol AnalysisHost: AnyObject, Sendable {
    /// The settings for a pass starting now.
    @MainActor func analysisSettings() -> AnalysisSettings
    /// One line for the strap log, tagged with the Test Centre domain it belongs to.
    @MainActor func diagnostic(_ line: String, domain: TestDomain?)

    /// A stored flag; false when never set.
    @MainActor func storedBool(_ key: String) -> Bool
    /// A stored string; nil when never set.
    @MainActor func storedString(_ key: String) -> String?
    @MainActor func store(_ value: Bool, forKey key: String)
    /// Stores `value`, or removes the key when it is nil.
    @MainActor func store(_ value: String?, forKey key: String)
    @MainActor func store(_ value: Double, forKey key: String)

    /// Records that a pass has started and owes a completion.
    @MainActor func passWillStart() -> AnalysisPassTicket
    /// Records a completed pass that took `elapsedSeconds` of uptime.
    @MainActor func passDidFinish(_ ticket: AnalysisPassTicket, elapsedSeconds: Double) -> AnalysisPassReport
    /// Yields CPU while the app is in the background; `mark` is the uptime the current work stretch began.
    func paceIfBackgrounded(since mark: inout UInt64) async
    /// The process's CPU seconds so far and the device's battery percent, for the rebuild's cost lines; nil
    /// where the platform cannot say.
    @MainActor func costReading() -> (cpuSeconds: Double?, batteryPercent: Int?)
}
