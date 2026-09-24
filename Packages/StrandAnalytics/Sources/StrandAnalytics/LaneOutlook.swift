import Foundation
import WhoopStore

// MARK: - Room left today, and when a high week settles (P6)
//
// Two questions a wearer asks of a lane, answered with the very functions that draw its band, so the
// answer can never disagree with the screen:
//
//   • ROOM — how much load can still be added today before the last seven days read "above usual", and
//     before they read "well above usual". Solved against `TrainingLoad.relativeLoad` and
//     `LaneEngine.thresholds` by bisection on today's total, because the personal edges themselves
//     move with the week being judged.
//   • SETTLING — if every day from tomorrow is a rest day, the first day on which `LaneEngine` reads the
//     lane about usual (or below) again, hysteresis included.
//
// Both describe load only. Neither says the room SHOULD be used or that rest is needed: that would need
// the performance evidence and recovery the verdict table reads.

/// How much load a lane can still take today, in the lane's own unit.
public struct LaneHeadroom: Equatable, Sendable {
    /// The day the room is for.
    public let day: String
    /// Load already logged on `day`.
    public let loggedToday: Double
    /// What can still be added before the week reads "above usual". Zero once it already does.
    public let beforeAbove: Double
    /// What can still be added before it reads "well above usual". Nil while the low-volume guard caps
    /// the lane at "above", where "well above" cannot be reached.
    public let beforeWellAbove: Double?

    public init(day: String, loggedToday: Double, beforeAbove: Double, beforeWellAbove: Double?) {
        self.day = day
        self.loggedToday = loggedToday
        self.beforeAbove = beforeAbove
        self.beforeWellAbove = beforeWellAbove
    }
}

public enum LaneOutlook {

    /// How far ahead the settling forecast looks. Three weeks of rest take any lane out of a high band.
    public static let settlingHorizonDays = 21

    // MARK: - Room

    /// The room left on `today`, or nil while the lane has no band to leave (too few sessions, no
    /// comparison yet) or today itself could not be priced.
    public static func headroom(dailyByDay: [String: Double], unknownDays: Set<String> = [],
                                activity: LaneActivity, lane: TrainingLaneKind,
                                today: String) -> LaneHeadroom? {
        guard !unknownDays.contains(today) else { return nil }
        let current = LaneEngine.reading(dailyByDay: dailyByDay, unknownDays: unknownDays, activity: activity,
                                         lane: lane, through: today)
        guard current.guardState != .tooFewSessions, current.trend != nil, current.thresholds != nil else {
            return nil
        }
        let logged = dailyByDay[today] ?? 0

        /// Whether the week reads past `edge` with `total` logged today.
        func exceeds(_ edge: KeyPath<LaneThresholds, Double>, total: Double) -> Bool? {
            var series = dailyByDay
            series[today] = total
            let relative = TrainingLoad.relativeLoad(dailyByDay: series, through: today, unknownDays: unknownDays,
                                                     coverage: .lane)
            guard let ratio = relative.trend?.ratio, let thresholds = LaneEngine.thresholds(for: relative) else {
                return nil
            }
            return ratio > thresholds[keyPath: edge]
        }

        /// The largest total for today that keeps the week at or under `edge`.
        func limit(_ edge: KeyPath<LaneThresholds, Double>) -> Double? {
            guard let atRest = exceeds(edge, total: 0) else { return nil }
            if atRest { return 0 }
            var low = 0.0
            var high = max(1, (current.trend?.baselinePerDay ?? 1) * Double(TrainingLoad.recentWindow))
            var doublings = 0
            while exceeds(edge, total: high) == false {
                low = high
                high *= 2
                doublings += 1
                if doublings > 40 { return nil }
            }
            for _ in 0..<60 {
                let middle = (low + high) / 2
                if exceeds(edge, total: middle) == true { high = middle } else { low = middle }
            }
            return low
        }

        guard let aboveLimit = limit(\.above) else { return nil }
        let wellAboveLimit = current.guardState == .lowVolumeCap ? nil : limit(\.wellAbove)
        return LaneHeadroom(day: today, loggedToday: logged,
                            beforeAbove: max(0, aboveLimit - logged),
                            beforeWellAbove: wellAboveLimit.map { max(0, $0 - logged) })
    }

    // MARK: - Settling

    /// With every day after `day` a rest day, the first day within `settlingHorizonDays` on which the lane
    /// reads about usual or below. Nil when it is not above usual on `day`, or rest alone would not bring
    /// it back within the horizon.
    public static func backToUsual(dailyByDay: [String: Double], unknownDays: Set<String> = [],
                                   activity: LaneActivity, lane: TrainingLaneKind,
                                   from day: String) -> String? {
        let now = LaneEngine.reading(dailyByDay: dailyByDay, unknownDays: unknownDays, activity: activity,
                                     lane: lane, through: day)
        guard now.band == .higher || now.band == .muchHigher else { return nil }
        // Days after `day` carry no entry, which the lane reads as rest.
        let future = dailyByDay.filter { $0.key <= day }
        let days = (1...settlingHorizonDays).map { WeeklyDigestEngine.addDays(day, $0) }
        let readings = LaneEngine.readings(dailyByDay: future, unknownDays: unknownDays, activity: activity,
                                           lane: lane, days: days)
        return zip(days, readings).first { $0.1.band == .usual || $0.1.band == .below }?.0
    }
}

// MARK: - Strength band per muscle group (P6)

/// The strength lane's band for each muscle group on its own: hard sets per group and day — the Strength
/// screen's own counting, each set once on its primary group — read by `LaneEngine` with the strength
/// lane's guards. A group trained on fewer than two days a week is capped at "above", as the lane is.
public enum MuscleGroupLoad {

    /// Hard sets per muscle group per local day.
    public static func setsByGroupByDay(_ workouts: [HevyWorkout], templates: [String: HevyExerciseTemplate],
                                        tzOffsetSeconds: Int = 0) -> [HevyMuscleGroup: [String: Double]] {
        var out: [HevyMuscleGroup: [String: Double]] = [:]
        for workout in workouts {
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)
            let sets = StrengthSession.hardSetsByMuscle([workout], templates: templates).primary
            for (group, count) in sets where count > 0 {
                out[group, default: [:]][day, default: 0] += Double(count)
            }
        }
        return out
    }

    /// Each group's reading through `day`. Groups without a band are left out.
    public static func bands(_ workouts: [HevyWorkout], templates: [String: HevyExerciseTemplate],
                             through day: String, tzOffsetSeconds: Int = 0) -> [HevyMuscleGroup: RelativeLoadBand] {
        var out: [HevyMuscleGroup: RelativeLoadBand] = [:]
        for (group, byDay) in setsByGroupByDay(workouts, templates: templates, tzOffsetSeconds: tzOffsetSeconds) {
            let activity = LaneActivity(sessionsByDay: byDay.mapValues { _ in 1 })
            let reading = LaneEngine.reading(dailyByDay: byDay, activity: activity, lane: .strength, through: day)
            if let band = reading.band { out[group] = band }
        }
        return out
    }
}
