#if os(iOS)
import CallKit
import Foundation
import UIKit

/// Wrist alert for incoming calls: buzzes the strap for as long as a call rings, like an Apple Watch,
/// and stops once it is answered, declined or ends. iOS counterpart of Android's `CallAlertController`
/// (#66), which instead stops after 4 buzzes. Same privacy line: NOOP only learns THAT a call is ringing,
/// never who is calling or from which app.
///
/// Detection is `CXCallObserver`, which sees every CallKit call on the phone: regular phone calls,
/// FaceTime, and VoIP apps that ring through CallKit (WhatsApp audio and video, Messenger, Teams, …).
/// It needs no permission or entitlement.
///
/// The limit is iOS itself: call changes are only delivered while NOOP is running. In the background
/// the app runs only when the strap wakes it with a Bluetooth frame, so `poll()` re-checks the call list
/// on inbound frames. With Continuous HRV capture on, the strap sends a frame every second and alerts
/// arrive within about a second; without it, frames are sparse and an alert can be missed. Nothing can
/// help once the app has been force-quit from the app switcher: iOS does not relaunch it.
@MainActor
final class CallBuzzMonitor: NSObject, CXCallObserverDelegate {
    static let enabledKey = "notif.calls.enabled"

    /// One burst is 2 pulses, about 1.3 s on the strap (a 3-pulse burst measured ~2 s, "Sequence fired" →
    /// "SEQ done"), so a new burst every 2 s keeps the wrist buzzing with a short pause between bursts.
    /// Kept short because a burst already sent plays out after a double-tap silences the alert.
    static let repeatInterval: TimeInterval = 2
    /// Self-heal ceiling (Android `MAX_RING_WINDOW_MS`): a cycle never runs longer than this even if
    /// the call's end is never observed. Longer than any normal ring before voicemail.
    static let maxRingWindow: TimeInterval = 90

    /// On only when both this alert and the wrist-alerts master switch (`notif.masterEnabled`, Settings ›
    /// Notifications) are on, like every other ambient wrist buzz.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && UserDefaults.standard.bool(forKey: "notif.masterEnabled")
    }

    /// What one buzz attempt did, so the log names the actual reason a buzz did not happen.
    enum BuzzOutcome { case sent, notConnected, unsupportedStrap }

    private let observer = CXCallObserver()
    /// Fires one buzz and says whether it went out (`BLEManager.buzzCallAlert`).
    private let buzz: () -> BuzzOutcome
    private let log: (String) -> Void

    private var cycleCallID: UUID?
    /// Set by a strap double-tap (`dismissFromStrap`), or when the active strap has no call buzz: no more
    /// buzzes for `cycleCallID`, even though it may keep ringing. Cleared when the call stops ringing.
    private var dismissed = false
    private var cycleStartedAt: Date?
    private var buzzCount = 0
    private var lastBuzzAt: Date?
    private var repeatWork: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastPollAt = Date.distantPast
    /// The "not connected" line is written once per call, not on every retry.
    private var reportedMiss = false

    init(buzz: @escaping () -> BuzzOutcome, log: @escaping (String) -> Void) {
        self.buzz = buzz
        self.log = log
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        // Delivered on the main queue (see `setDelegate`), so this is already main-actor isolated.
        MainActor.assumeIsolated { evaluate() }
    }

    /// Re-check the call list, throttled to once a second. Called on every inbound strap frame, which
    /// is what catches a call that started while the app was suspended.
    func poll() {
        let now = Date()
        guard now.timeIntervalSince(lastPollAt) >= 1 else { return }
        lastPollAt = now
        evaluate()
    }

    func evaluate() {
        guard Self.isEnabled, let call = ringingCall() else {
            stopCycle()
            return
        }
        if call.uuid != cycleCallID {
            startCycle(for: call.uuid)
        } else {
            tick()
        }
    }

    /// True while the strap is being buzzed for a ringing call (not silenced, not past the ceiling).
    /// BLEManager holds off strap-event-triggered history syncs meanwhile: each buzz makes the strap
    /// report HAPTICS_FIRED, which would start a multi-second offload, and on hardware a DOUBLE_TAP sensed
    /// during that offload reached the phone ~1.5 s late, so silencing seemed to need a second try.
    var isAlerting: Bool {
        guard cycleCallID != nil, !dismissed, let start = cycleStartedAt else { return false }
        return Date().timeIntervalSince(start) < Self.maxRingWindow
    }

    /// Strap double-tap while a call is buzzing: stop buzzing for this call and return true (the tap is
    /// consumed). Returns false when nothing is buzzing, so the tap does whatever it normally does.
    /// The call itself keeps ringing on the phone: iOS lets an app end only calls its own CXProvider
    /// reported, so no app can answer, decline or end a phone, FaceTime or WhatsApp call
    /// (ryanbr/noop#2812 confirmed the refusal on iOS 26: com.apple.CallKit.error.requesttransaction 1).
    func dismissFromStrap() -> Bool {
        guard let id = cycleCallID, !dismissed, ringingCall()?.uuid == id else { return false }
        dismissed = true
        repeatWork?.cancel()
        repeatWork = nil
        log("Call alert: stopped by double-tap after \(buzzCount) buzz\(buzzCount == 1 ? "" : "es")")
        endBackgroundTask()
        return true
    }

    /// An incoming call that is still ringing: not placed by us, not answered, not ended.
    private func ringingCall() -> CXCall? {
        observer.calls.first { !$0.isOutgoing && !$0.hasConnected && !$0.hasEnded }
    }

    private func startCycle(for id: UUID) {
        stopCycle()
        cycleCallID = id
        cycleStartedAt = Date()
        // Ask for background time so the repeat buzzes still fire if iOS would otherwise suspend us
        // mid-ring (iOS grants roughly 30 s; after that the strap's frames keep driving `poll()`).
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CallBuzz") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        log("Call alert: incoming call ringing")
        tick()
    }

    private func tick() {
        repeatWork?.cancel()
        repeatWork = nil
        let now = Date()
        let expired = cycleStartedAt.map { now.timeIntervalSince($0) >= Self.maxRingWindow } ?? true
        // Silenced by a double-tap, or past the ceiling: stop buzzing. `cycleCallID` is kept so the same
        // call can't restart the cycle.
        guard !dismissed, !expired else {
            endBackgroundTask()
            return
        }
        let due = lastBuzzAt.map { now.timeIntervalSince($0) >= Self.repeatInterval - 0.25 } ?? true
        if due {
            switch buzz() {
            case .sent:
                buzzCount += 1
                lastBuzzAt = now
                if buzzCount == 1 { log("Call alert: buzzing") }
            case .notConnected:
                if lastBuzzAt == nil && !reportedMiss {
                    reportedMiss = true
                    log("Call alert: strap not connected, will retry")
                }
            case .unsupportedStrap:
                // Only a WHOOP 5.0/MG has a call buzz (`BLEManager.buzzCallAlert`); stop for this call.
                log("Call alert: not sent, the active strap is not a WHOOP 5.0/MG")
                dismissed = true
                endBackgroundTask()
                return
            }
        }
        let wait = lastBuzzAt.map { max(0.25, Self.repeatInterval - now.timeIntervalSince($0)) } ?? 1
        // Scheduled on the main queue, so the work item runs main-actor isolated.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        repeatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func stopCycle() {
        guard cycleCallID != nil else { return }
        if !dismissed { log("Call alert: stopped after \(buzzCount) buzz\(buzzCount == 1 ? "" : "es")") }
        repeatWork?.cancel()
        repeatWork = nil
        cycleCallID = nil
        dismissed = false
        cycleStartedAt = nil
        buzzCount = 0
        lastBuzzAt = nil
        reportedMiss = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif
