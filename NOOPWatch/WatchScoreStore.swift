import Foundation
import Combine
import WatchConnectivity
import WidgetKit
import StrandDesign

// MARK: - WatchScoreStore — the watch side of the phone->watch bridge
//
// Activates WCSession on the watch, receives the latest score snapshot the phone pushed via
// `updateApplicationContext` (latest-state semantics, no queue buildup), persists it into the shared
// App Group so the complication can read the same bytes, and reloads the complication timelines so the
// watch face matches the glance. The phone is the brain; this object never computes a score, it only
// carries the one the phone already earned.
//
// The published `snapshot` is what the glance binds to. It starts from whatever was last persisted to the
// App Group (so a relaunch shows the last-known scores immediately, with an honest "as of" age) and is
// nil only on a truly fresh install, which the glance renders as the "open NOOP on your iPhone" state.
final class WatchScoreStore: NSObject, ObservableObject, WCSessionDelegate {

    /// The latest snapshot the watch knows about. nil = nothing has ever synced (fresh install).
    @Published private(set) var snapshot: WatchScoreSnapshot?
    @Published private(set) var strengthWorkout: StrengthWorkoutCompanionState?

    /// The shared App Group suite the watch app + its complication both read/write. `Bundle.main` is
    /// process-global, so this is exactly the lookup `WatchScoreSnapshot.appGroupId` itself performs —
    /// deferring to it directly (rather than repeating the lookup here) keeps the resolution in ONE
    /// place so the writer and readers can't desync on it.
    static let suiteName: String = WatchScoreSnapshot.appGroupId

    /// The key the complication also reads. The single source of truth lives in the shared contract.
    static let storageKey = WatchScoreSnapshot.storageKey

    /// Prevent duplicate immediate requests when activation and reachability callbacks arrive together.
    private var requestedLatestForCurrentReachability = false

    override init() {
        super.init()
        // Show the last-known snapshot straight away (honest about its age via the glance's "as of").
        snapshot = Self.loadPersisted()
        activate()
    }

    /// Bring up the WCSession so the phone can reach us. Guarded because the simulator / an unpaired
    /// state can report the session unsupported, in which case we simply run on the last persisted snapshot.
    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: Persistence (shared with the complication)

    /// Read the last snapshot the phone delivered, if any. The complication uses the same key.
    static func loadPersisted() -> WatchScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist a snapshot into the shared group so the complication reads the SAME bytes the glance shows.
    /// They can never disagree because there is one source of truth.
    private func persist(_ snap: WatchScoreSnapshot) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName),
              let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Apply a freshly received snapshot: store it, publish to the glance, refresh the complication.
    /// Hops to the main actor because it touches @Published state and WidgetCenter.
    private func apply(_ snap: WatchScoreSnapshot) {
        persist(snap)
        DispatchQueue.main.async {
            self.snapshot = snap
            // The phone just pushed new scores, so pull the complication timelines forward now rather
            // than waiting for WidgetKit's own cadence.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Decode a WatchScoreSnapshot out of a WatchConnectivity payload. The phone encodes the Codable
    /// snapshot to Data under "snapshot"; we tolerate a missing/garbled payload by simply ignoring it.
    private func decode(from payload: [String: Any]) -> WatchScoreSnapshot? {
        guard let data = payload[WatchScoreSnapshot.contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
    }

    private func applyStrengthWorkout(from payload: [String: Any]) {
        let state = (payload[StrengthWorkoutCompanionState.contextKey] as? Data)
            .flatMap { try? JSONDecoder().decode(StrengthWorkoutCompanionState.self, from: $0) }
        DispatchQueue.main.async { self.strengthWorkout = state }
    }

    func send(_ kind: StrengthWorkoutCompanionCommand.Kind) {
        guard let state = strengthWorkout, WCSession.isSupported() else { return }
        let command = StrengthWorkoutCompanionCommand(
            sessionId: state.sessionId, expectedRevision: state.revision, kind: kind)
        guard let data = try? JSONEncoder().encode(command) else { return }
        WCSession.default.sendMessage([StrengthWorkoutCompanionState.commandKey: data],
                                      replyHandler: nil, errorHandler: nil)
    }

    func sendTelemetry(bpm: Int?, sampleCount: Int) {
        guard let state = strengthWorkout, WCSession.isSupported() else { return }
        let value = StrengthWorkoutCompanionTelemetry(
            sessionId: state.sessionId, bpm: bpm, sampleCount: sampleCount,
            recordedAtTs: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(value) else { return }
        WCSession.default.sendMessage([StrengthWorkoutCompanionTelemetry.messageKey: data],
                                      replyHandler: nil, errorHandler: nil)
    }

    /// Ask the companion for its cached latest state. `updateApplicationContext` remains the durable
    /// background path; this immediate request closes the fresh-install/relaunch gap when both apps are
    /// reachable and avoids waiting for the phone's next dashboard refresh.
    private func requestLatestIfReachable(_ session: WCSession) {
        guard session.activationState == .activated, session.isReachable,
              !requestedLatestForCurrentReachability else { return }
        requestedLatestForCurrentReachability = true
        session.sendMessage([WatchScoreSnapshot.requestLatestKey: true]) { [weak self] reply in
            guard let self else { return }
            if let snap = self.decode(from: reply) { self.apply(snap) }
            self.applyStrengthWorkout(from: reply)
        } errorHandler: { [weak self] _ in
            // A later reachability transition may retry; application context still provides fallback.
            self?.requestedLatestForCurrentReachability = false
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // On activation the system hands us the most recent application context the phone set, even if it
        // was set while we were not running. Pick it up so a relaunch immediately reflects the latest scores.
        if let snap = decode(from: session.receivedApplicationContext) {
            apply(snap)
        }
        applyStrengthWorkout(from: session.receivedApplicationContext)
        requestLatestIfReachable(session)
    }

    /// The phone calls `updateApplicationContext` whenever its dashboard refreshes. Latest-state only, so
    /// we always have the freshest scores without a backlog of stale messages.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let snap = decode(from: applicationContext) {
            apply(snap)
        }
        applyStrengthWorkout(from: applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            requestLatestIfReachable(session)
        } else {
            requestedLatestForCurrentReachability = false
        }
    }
}
