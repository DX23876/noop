import Foundation

/// Decides WHEN the live workout's voice speaks; what it says is `WorkoutVoiceCoach`'s job.
///
/// With a route it fires on each full split (kilometre or mile), without one on each fixed span of active
/// time. Both read ACTIVE elapsed seconds, so a pause neither triggers an announcement nor lengthens a split.
/// A GPS jump that crosses several split marks at once announces only the newest one, with the time spread
/// over every split it covers: reading out three splits back to back would be noise.
struct WorkoutAnnouncementPlanner: Equatable {
    enum Mode: Equatable {
        /// Announce every `splitMeters` of route distance.
        case distance(splitMeters: Double)
        /// Announce every `intervalSeconds` of active time.
        case time(intervalSeconds: Int)
    }

    enum Event: Equatable {
        /// Split `index` (1-based) reached. `splitSeconds` is the active time since the previous announced mark,
        /// which lies `splits` marks back (usually 1), so the pace per split is `splitSeconds / splits`.
        case split(index: Int, splits: Int, splitSeconds: Int, elapsedSeconds: Int)
        /// Another interval of active time has passed.
        case interval(elapsedSeconds: Int)
    }

    let mode: Mode
    /// Splits or intervals already announced.
    private(set) var announcedCount = 0
    /// Active elapsed seconds at the last announced mark.
    private(set) var lastMarkElapsed = 0

    init(mode: Mode) {
        self.mode = mode
    }

    /// Feeds the current state; returns an event when a new mark was reached.
    mutating func update(distanceMeters: Double?, elapsedSeconds: Int) -> Event? {
        switch mode {
        case .distance(let splitMeters):
            guard splitMeters > 0, let distanceMeters, distanceMeters.isFinite else { return nil }
            let reached = Int(distanceMeters / splitMeters)
            guard reached > announcedCount else { return nil }
            let splitSeconds = max(elapsedSeconds - lastMarkElapsed, 0)
            let splits = reached - announcedCount
            announcedCount = reached
            lastMarkElapsed = elapsedSeconds
            return .split(index: reached, splits: splits, splitSeconds: splitSeconds,
                          elapsedSeconds: elapsedSeconds)
        case .time(let intervalSeconds):
            guard intervalSeconds > 0 else { return nil }
            let reached = elapsedSeconds / intervalSeconds
            guard reached > announcedCount else { return nil }
            announcedCount = reached
            lastMarkElapsed = elapsedSeconds
            return .interval(elapsedSeconds: elapsedSeconds)
        }
    }
}
