import Foundation

/// What starting a system workout session produced.
enum SystemWorkoutSessionStart: String {
    case started
    /// The OS cannot run one here (before iOS 26, or macOS).
    case unavailable
    /// Health has not been allowed to share workouts, which the system session requires.
    case notAuthorized
    case failed
}

/// The operating system's own notion of "a workout is running", for a live cardio session.
///
/// On iOS 26 and later this is an `HKWorkoutSession` on the iPhone: the system treats NOOP as a workout
/// app while it runs and can hand the session back after the app was terminated. It records and saves
/// nothing itself — the route, heart rate and the Apple Health export stay with NOOP's own recording and
/// write-back, so a finished walk is never written twice. Where it is unavailable the session simply runs
/// without it, on the location and Bluetooth background modes it always had.
@MainActor
protocol SystemWorkoutSession: AnyObject {
    func begin(sport: String, isOutdoor: Bool, start: Date) async -> SystemWorkoutSessionStart
    func pause()
    func resume()
    func end()
    /// After a relaunch: reattach to a session the system kept alive when NOOP restored its workout,
    /// otherwise end it. Returns true when one was recovered.
    func recover(keepRunning: Bool) async -> Bool
}
