#if os(iOS)
import Foundation
import HealthKit

/// `SystemWorkoutSession` on iPhone: an `HKWorkoutSession` for the duration of a live cardio workout.
///
/// iOS 26 brought workout sessions to iPhone. Running one tells the system a workout is in progress and
/// lets `recoverActiveWorkoutSession` hand it back after NOOP was terminated. It is deliberately started
/// without a live workout builder: NOOP's own recording owns the samples and route, and the existing
/// Apple Health write-back exports the finished workout under the wearer's settings. Saving from here as
/// well would create a second Health workout for the same walk.
///
/// Unlike on Apple Watch the session does not by itself keep an iPhone app running; the location and
/// Bluetooth background modes still do that. It is therefore strictly additive: any failure is reported
/// and the workout carries on without it.
@MainActor
final class PhoneWorkoutSession: NSObject, SystemWorkoutSession {
    private let store: HKHealthStore
    private var session: AnyObject?

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func begin(sport: String, isOutdoor: Bool, start: Date) async -> SystemWorkoutSessionStart {
        guard #available(iOS 26.0, *) else { return .unavailable }
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        guard store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return .notAuthorized }
        end()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = HealthKitBridge.activityType(forSport: sport)
        configuration.locationType = isOutdoor ? .outdoor : .indoor
        do {
            let workout = try HKWorkoutSession(healthStore: store, configuration: configuration)
            workout.delegate = self
            workout.startActivity(with: start)
            session = workout
            return .started
        } catch {
            return .failed
        }
    }

    func pause() {
        guard #available(iOS 26.0, *), let workout = session as? HKWorkoutSession else { return }
        workout.pause()
    }

    func resume() {
        guard #available(iOS 26.0, *), let workout = session as? HKWorkoutSession else { return }
        workout.resume()
    }

    func end() {
        guard #available(iOS 26.0, *), let workout = session as? HKWorkoutSession else { return }
        if workout.state != .ended { workout.end() }
        session = nil
    }

    func recover(keepRunning: Bool) async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let recovered: HKWorkoutSession? = await withCheckedContinuation { continuation in
            store.recoverActiveWorkoutSession { session, _ in continuation.resume(returning: session) }
        }
        guard let recovered else { return false }
        guard keepRunning else {
            // NOOP has no workout to attach it to any more; leaving it running would keep the system
            // showing a workout that is not happening.
            recovered.end()
            return false
        }
        recovered.delegate = self
        session = recovered
        return true
    }
}

extension PhoneWorkoutSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            if self?.session === workoutSession { self?.session = nil }
        }
    }
}
#endif
