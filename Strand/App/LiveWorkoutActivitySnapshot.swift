import Foundation

/// What the system surfaces (Lock Screen, Dynamic Island) show about the running session.
///
/// Platform-neutral on purpose: the session controller builds it on every platform, and only the iOS app
/// turns it into an ActivityKit content state. Times are absolute so the system can count elapsed time and
/// a rest countdown itself, without the app pushing an update every second.
struct LiveWorkoutActivitySnapshot: Equatable {
    enum Kind: String { case strength, cardio }

    var kind: Kind
    var title: String
    var startedAt: Date
    /// Set while the session is paused; elapsed time is frozen at this instant.
    var pausedAt: Date?
    /// Paused time before `pausedAt` (or before now, when running).
    var pausedSeconds: TimeInterval
    var bpm: Int?
    var zone: Int?
    var distanceM: Double?
    var paceSecPerKm: Double?
    var setsDone: Int?
    var setsTotal: Int?
    /// End of the current strength rest, when one is counting down.
    var restEndsAt: Date?

    /// The instant elapsed time counts from once pauses are taken out, for a system-rendered timer.
    var elapsedAnchor: Date { startedAt.addingTimeInterval(pausedSeconds) }

    /// Elapsed active seconds at `now`, for the frozen display while paused.
    func activeSeconds(at now: Date = Date()) -> Int {
        let end = pausedAt ?? now
        return max(0, Int(end.timeIntervalSince(startedAt) - pausedSeconds))
    }
}
