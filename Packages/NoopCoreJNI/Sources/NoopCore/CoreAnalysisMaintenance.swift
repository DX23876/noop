import Foundation
import StrandCore

/// Settings › Calculations › "If scores look wrong" for Android: what the iPhone's `AnalysisMaintenanceSettingsCard`
/// reads from the engine (the phase, the live progress, when the last repair finished) and the two repair actions
/// ("Refresh today", "Recalculate the last 21 days"), answered by the same shared code (`DailyAnalysis`).
///
/// Both actions are diagnostics. Neither touches the analysis recipe cursor: the Android pass never calls
/// `prepareAnalysisRecipe`, and `manuallyReanalyzeRecent` (which would fulfil a pending recipe migration) is not
/// used here. The 21 days are the pass the app already runs after a sync (`analyzeRecent(maxDays: 21, force: true,
/// allowDayReuse: false)`), asked for by the wearer.
///
/// The actions return at once and the page polls `analysis.maintenance`, as the iPhone card observes the engine,
/// so a pass of several minutes never holds a bridge call open.
public enum AnalysisMaintenanceState {
    /// What is running: an ordinary pass (after a sync or an edit), or one of the two repair actions.
    public enum Kind: String, Sendable { case background, recent, today }

    public struct Snapshot: Sendable, Equatable {
        public var task: Kind?
        /// When the last repair action finished (the iPhone's `analysisLastRunKey`), nil before one did.
        public var lastRun: Date?
        /// When the last tracked run finished, and the failure it ended with, if any.
        public var completedAt: Date?
        public var failure: String?
        public var progress: AnalysisProgress?
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var snapshot = Snapshot()
    }
    private static let box = Box()

    /// The key the iPhone keeps the last repair under; the core's UserDefaults carry it across launches.
    public static let lastRunKey = DailyAnalysis.analysisLastRunKey

    public static var snapshot: Snapshot {
        box.lock.lock(); defer { box.lock.unlock() }
        var s = box.snapshot
        if s.lastRun == nil {
            let ts = UserDefaults.standard.double(forKey: lastRunKey)
            if ts > 0 { s.lastRun = Date(timeIntervalSince1970: ts) }
        }
        return s
    }

    /// Marks `task` as running; false when something is already running, which is how the page's buttons stay
    /// disabled while a pass is in flight, as on the iPhone (`busy`).
    @discardableResult
    static func begin(_ task: Kind) -> Bool {
        box.lock.lock(); defer { box.lock.unlock() }
        guard box.snapshot.task == nil else { return false }
        box.snapshot.task = task
        box.snapshot.failure = nil
        box.snapshot.progress = nil
        return true
    }

    /// The pass started: an ordinary one takes the slot if no repair asked for it first. A repair that asked keeps
    /// its own label, so the page says "Recalculating the last 21 days…" while the pass runs.
    static func passStarted() {
        box.lock.lock(); defer { box.lock.unlock() }
        if box.snapshot.task == nil { box.snapshot.task = .background; box.snapshot.failure = nil }
    }

    static func note(progress: AnalysisProgress?) {
        box.lock.lock(); defer { box.lock.unlock() }
        box.snapshot.progress = progress
    }

    /// The tracked run ended. A repair that succeeded is the "last completed" moment. A daily pass that ends
    /// while "Refresh today" is still running (`unless: .today`) leaves that slot alone, so the page keeps its
    /// button disabled until the refresh itself finishes.
    static func finish(failure: String? = nil, now: Date = Date(), unless running: Kind? = nil) {
        box.lock.lock()
        let task = box.snapshot.task
        if let running, task == running { box.lock.unlock(); return }
        box.snapshot.task = nil
        box.snapshot.progress = nil
        box.snapshot.failure = failure
        box.snapshot.completedAt = now
        let repaired = failure == nil && (task == .recent || task == .today)
        if repaired { box.snapshot.lastRun = now }
        box.lock.unlock()
        if repaired { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastRunKey) }
    }

    /// Test hook: forget everything.
    static func reset() {
        box.lock.lock(); box.snapshot = Snapshot(); box.lock.unlock()
    }
}

enum CoreAnalysisMaintenance {
    /// A duration in the coarse form the card prints (`AnalysisProgressFormat.coarseDuration`): seconds below a
    /// minute, rounded UP to 5 so the number does not flicker, whole minutes above it, also rounded up. The
    /// wording (seconds or minutes) is the screen's.
    struct Coarse: Encodable, Equatable {
        let value: Int
        let unit: String
        init(_ seconds: TimeInterval) {
            let s = max(0, seconds)
            if s < 60 {
                value = max(5, (Int(s.rounded(.up)) + 4) / 5 * 5)
                unit = "s"
            } else {
                value = Int((s / 60).rounded(.up))
                unit = "min"
            }
        }
    }

    /// What the card needs of a running pass, decided here from `AnalysisProgress` so both platforms stall,
    /// estimate and round alike; the sentence built from it is each platform's.
    struct ProgressWire: Encodable, Equatable {
        let stage: String
        let fraction: Double
        /// The day the pass is on (1-based), and how many it covers.
        let day: Int
        let totalDays: Int
        let unchanged: Int
        /// Withheld until enough days have completed for an estimate to mean something.
        let eta: Coarse?
        /// How long since the last step, and whether that is long enough to name instead of calling it working.
        let gap: Coarse
        let stalled: Bool

        init(_ p: AnalysisProgress, now: Date) {
            switch p.stage {
            case .preparing: stage = "preparing"
            case .scanning: stage = "scanning"
            case .finishing: stage = "finishing"
            }
            fraction = p.fraction
            day = p.completedDays + 1
            totalDays = p.totalDays
            unchanged = p.reusedDays
            eta = p.estimatedSecondsRemaining(now: now).map(Coarse.init)
            gap = Coarse(p.secondsSinceLastStep(now: now))
            stalled = p.looksStalled(now: now)
        }
    }

    struct StatusWire: Encodable {
        /// "idle" or "working".
        let phase: String
        /// While working: "background", "recent" or "today".
        let task: String?
        let lastRun: Double?
        let completedAt: Double?
        /// "noCurrentDayActivity" or "unfinished" after a repair that did not finish.
        let failure: String?
        let progress: ProgressWire?
    }

    static func status(now: Date = Date()) -> StatusWire {
        let s = AnalysisMaintenanceState.snapshot
        return StatusWire(phase: s.task == nil ? "idle" : "working", task: s.task?.rawValue,
                          lastRun: s.lastRun?.timeIntervalSince1970,
                          completedAt: s.completedAt?.timeIntervalSince1970, failure: s.failure,
                          progress: s.progress.map { ProgressWire($0, now: now) })
    }

    /// The profile and the wearer's choices as `shadow analyze` takes them, as one JSON object.
    static func request(_ args: [String: Any]) -> (CoreAnalysis.Profile, CoreAnalysis.Settings)? {
        guard let sex = args["sex"] as? String else { return nil }
        func double(_ k: String) -> Double { (args[k] as? NSNumber)?.doubleValue ?? 0 }
        func int(_ k: String) -> Int { (args[k] as? NSNumber)?.intValue ?? 0 }
        func bool(_ k: String) -> Bool { (args[k] as? NSNumber)?.boolValue ?? false }
        var settings = CoreAnalysis.Settings(effortBanister: bool("effortBanister"), sleepStagerV2: bool("sleepStagerV2"),
                                             motionAwareWake: bool("motionAwareWake"),
                                             deepHrvWindow: bool("deepHrvWindow"),
                                             dayCycleMode: args["dayCycleMode"] as? String,
                                             healthspan: bool("healthspan"), rhythmAge: bool("rhythmAge"))
        var profile = CoreAnalysis.Profile(age: int("age"), sex: sex, weightKg: double("weightKg"),
                                           heightCm: double("heightCm"), hrMaxOverride: int("hrMaxOverride"))
        if let extras = args["extras"] as? String { CoreAnalysis.applyExtras(extras, to: &settings, profile: &profile) }
        // A repair never rescored the whole history: that is the Lab switch's own pass.
        settings.historyRescore = false
        return (profile, settings)
    }

    static func run(_ op: String, _ args: [String: Any]) async -> String? {
        switch op {
        case "analysis.maintenance":
            return CoreRead.json(status())
        case "analysis.reanalyzeRecent":
            guard let (profile, settings) = request(args) else { return #"{"error":"invalid"}"# }
            guard let session = ShadowSession.storeAndPath, !session.path.isEmpty else { return #"{"error":"noStore"}"# }
            guard AnalysisMaintenanceState.begin(.recent) else { return #"{"started":false,"reason":"busy"}"# }
            // The pass runs in the session's queue, beside the strap's frames, and waits while the strap is
            // handing history over, as every other pass does.
            ShadowSession.send(.analyze(profile, settings))
            return #"{"started":true}"#
        case "analysis.refreshToday":
            guard let (profile, settings) = request(args) else { return #"{"error":"invalid"}"# }
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            guard AnalysisMaintenanceState.begin(.today) else { return #"{"started":false,"reason":"busy"}"# }
            let deviceId = ShadowSession.activeDeviceId
            Task { @MainActor in
                // Outside the pass queue, so it waits as a queued pass does while the strap hands history over:
                // running the engine then holds this actor past the time the client waits for a chunk ack.
                while ShadowSession.holdsAnalysis { try? await Task.sleep(for: .milliseconds(500)) }
                let ok = await CoreAnalysis.refreshToday(store: store, deviceId: deviceId, profile: profile,
                                                         settings: settings)
                AnalysisMaintenanceState.finish(failure: ok ? nil : "noCurrentDayActivity")
            }
            return #"{"started":true}"#
        default:
            return nil
        }
    }
}
