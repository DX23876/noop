#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?
        /// Present while a workout session runs; the activity then shows the workout instead of the plain
        /// live-HR summary. OPTIONAL so an activity started by an older build still decodes.
        public var workout: Workout?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil, workout: Workout? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.workout = workout
        }
    }

    /// The running workout, with absolute times so elapsed time and a rest countdown are counted by the
    /// system rather than by per-second pushes.
    public struct Workout: Codable, Hashable {
        public enum Kind: String, Codable, Hashable { case strength, cardio }
        public var kind: Kind
        public var title: String
        /// Elapsed time counts from here once pauses are taken out.
        public var elapsedAnchor: Date
        /// Frozen elapsed seconds while paused; nil while running.
        public var pausedElapsedSeconds: Int?
        public var zone: Int?
        public var distanceM: Double?
        public var paceSecPerKm: Double?
        public var setsDone: Int?
        public var setsTotal: Int?
        public var restEndsAt: Date?

        public init(kind: Kind, title: String, elapsedAnchor: Date, pausedElapsedSeconds: Int?, zone: Int?,
                    distanceM: Double?, paceSecPerKm: Double?, setsDone: Int?, setsTotal: Int?,
                    restEndsAt: Date?) {
            self.kind = kind
            self.title = title
            self.elapsedAnchor = elapsedAnchor
            self.pausedElapsedSeconds = pausedElapsedSeconds
            self.zone = zone
            self.distanceM = distanceM
            self.paceSecPerKm = paceSecPerKm
            self.setsDone = setsDone
            self.setsTotal = setsTotal
            self.restEndsAt = restEndsAt
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
