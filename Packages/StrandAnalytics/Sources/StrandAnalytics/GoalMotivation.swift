import Foundation

// MARK: - Goal motivation
//
// Streaks, badges and personal records for the goals area (plan §17e). Everything here is arithmetic on
// the wearer's own history, recomputed on every refresh: nothing is stored but which badges the wearer
// has already seen, so a badge can never disagree with the data it was earned from.
//
// Day keys are "yyyy-MM-dd" local days, the same keys the rest of the goals code uses.

public enum GoalMotivation {

    // MARK: Streaks

    public struct Streak: Equatable, Sendable {
        /// Days in a row the goal was met, ending today when today is already met, else yesterday.
        /// Today still being open never breaks a streak.
        public let current: Int
        /// The longest run in the history given.
        public let best: Int
        /// The day each streak length was first reached, for streak badges (index 0 = length 1).
        public let firstReached: [String]

        public init(current: Int, best: Int, firstReached: [String]) {
            self.current = current
            self.best = best
            self.firstReached = firstReached
        }
    }

    /// Consecutive days on which `values[day] >= target`.
    ///
    /// - `firstDay`: where the history starts (the goal's creation day or the oldest data).
    /// - `isScheduled`: days the goal does not ask for (a weekday schedule) are skipped; they neither
    ///   count nor break the run.
    /// A scheduled day without a reading breaks the run: the goal was not shown to be met.
    public static func streak(values: [String: Double], target: Double, firstDay: String, today: String,
                              isScheduled: (String) -> Bool = { _ in true }) -> Streak {
        guard target > 0, firstDay <= today else { return Streak(current: 0, best: 0, firstReached: []) }
        var run = 0
        var best = 0
        var firstReached: [String] = []
        var day = firstDay
        while day <= today {
            if isScheduled(day) {
                let met = (values[day] ?? 0) >= target
                // Today extends the run when met but never resets it: the day is not over yet.
                if met { run += 1 } else if day != today { run = 0 }
                if run > best {
                    best = run
                    if firstReached.count < run { firstReached.append(day) }
                }
            }
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        return Streak(current: run, best: best, firstReached: firstReached)
    }

    // MARK: Badges

    public enum BadgeFamily: String, CaseIterable, Sendable {
        /// One day with at least N steps.
        case dailySteps
        /// All measured steps added up.
        case lifetimeSteps
        /// N days in a row of the daily step goal.
        case stepStreak
        /// N weekly goals reached (each reached goal-week counts).
        case weeksReached
        /// N workouts recorded.
        case workouts
    }

    public struct Badge: Identifiable, Equatable, Sendable {
        public let family: BadgeFamily
        public let threshold: Int
        /// The day it was earned; nil while it is still ahead.
        public let earnedOn: String?
        public var id: String { "\(family.rawValue).\(threshold)" }
        public var isEarned: Bool { earnedOn != nil }

        public init(family: BadgeFamily, threshold: Int, earnedOn: String?) {
            self.family = family
            self.threshold = threshold
            self.earnedOn = earnedOn
        }
    }

    public static let thresholds: [BadgeFamily: [Int]] = [
        .dailySteps: [10_000, 15_000, 20_000, 25_000, 30_000, 40_000],
        .lifetimeSteps: [100_000, 250_000, 500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000, 25_000_000],
        .stepStreak: [3, 7, 14, 30, 60, 100, 200, 365],
        .weeksReached: [1, 5, 10, 25, 52, 100],
        .workouts: [10, 25, 50, 100, 250, 500, 1_000],
    ]

    /// Every badge with the day it was earned (or nil), in family order and rising threshold.
    ///
    /// - `stepsByDay`: measured steps per day (never an estimate).
    /// - `stepStreak`: the daily step goal's streak (its `firstReached` dates).
    /// - `reachedWeeks`: the end day of each reached goal-week, one entry per goal and week.
    /// - `workoutDays`: the day of each recorded workout, one entry per workout.
    public static func badges(stepsByDay: [String: Int], stepStreak: Streak?,
                              reachedWeeks: [String], workoutDays: [String]) -> [Badge] {
        let days = stepsByDay.keys.sorted()
        var result: [Badge] = []

        for threshold in thresholds[.dailySteps] ?? [] {
            let first = days.first { (stepsByDay[$0] ?? 0) >= threshold }
            result.append(Badge(family: .dailySteps, threshold: threshold, earnedOn: first))
        }

        var total = 0
        var lifetime: [Int: String] = [:]
        let lifetimeLevels = thresholds[.lifetimeSteps] ?? []
        for day in days {
            total += max(0, stepsByDay[day] ?? 0)
            for level in lifetimeLevels where lifetime[level] == nil && total >= level { lifetime[level] = day }
        }
        for level in lifetimeLevels { result.append(Badge(family: .lifetimeSteps, threshold: level, earnedOn: lifetime[level])) }

        for level in thresholds[.stepStreak] ?? [] {
            let reached = stepStreak.flatMap { $0.firstReached.count >= level ? $0.firstReached[level - 1] : nil }
            result.append(Badge(family: .stepStreak, threshold: level, earnedOn: reached))
        }

        let weeks = reachedWeeks.sorted()
        for level in thresholds[.weeksReached] ?? [] {
            result.append(Badge(family: .weeksReached, threshold: level,
                                earnedOn: weeks.count >= level ? weeks[level - 1] : nil))
        }

        let workouts = workoutDays.sorted()
        for level in thresholds[.workouts] ?? [] {
            result.append(Badge(family: .workouts, threshold: level,
                                earnedOn: workouts.count >= level ? workouts[level - 1] : nil))
        }
        return result
    }

    /// The next badge still ahead in a family, with how far the wearer is (0…1).
    public static func nextBadge(in family: BadgeFamily, badges: [Badge], progressValue: Double) -> (badge: Badge, fraction: Double)? {
        guard let next = badges.first(where: { $0.family == family && !$0.isEarned }) else { return nil }
        let previous = badges.last(where: { $0.family == family && $0.isEarned })?.threshold ?? 0
        let span = Double(next.threshold - previous)
        let fraction = span > 0 ? (progressValue - Double(previous)) / span : 0
        return (next, min(1, max(0, fraction)))
    }

    // MARK: Records

    public struct Records: Equatable, Sendable {
        public var bestStepDay: (day: String, steps: Int)?
        /// The best training week by step total, keyed by its first day.
        public var bestStepWeek: (start: String, steps: Int)?
        public var mostWorkoutsWeek: (start: String, count: Int)?
        public var longestStepStreak: Int

        public init(bestStepDay: (day: String, steps: Int)? = nil, bestStepWeek: (start: String, steps: Int)? = nil,
                    mostWorkoutsWeek: (start: String, count: Int)? = nil, longestStepStreak: Int = 0) {
            self.bestStepDay = bestStepDay
            self.bestStepWeek = bestStepWeek
            self.mostWorkoutsWeek = mostWorkoutsWeek
            self.longestStepStreak = longestStepStreak
        }

        public static func == (a: Records, b: Records) -> Bool {
            a.bestStepDay?.day == b.bestStepDay?.day && a.bestStepDay?.steps == b.bestStepDay?.steps
                && a.bestStepWeek?.start == b.bestStepWeek?.start && a.bestStepWeek?.steps == b.bestStepWeek?.steps
                && a.mostWorkoutsWeek?.start == b.mostWorkoutsWeek?.start
                && a.mostWorkoutsWeek?.count == b.mostWorkoutsWeek?.count
                && a.longestStepStreak == b.longestStepStreak
        }
    }

    /// Personal bests. Weeks follow the wearer's training week (`firstWeekday`). Ties keep the earlier
    /// date: a record is broken by doing more, not by doing the same again.
    public static func records(stepsByDay: [String: Int], workoutDays: [String], firstWeekday: Int,
                               longestStepStreak: Int) -> Records {
        var records = Records(longestStepStreak: longestStepStreak)
        for day in stepsByDay.keys.sorted() {
            let steps = stepsByDay[day] ?? 0
            if steps > (records.bestStepDay?.steps ?? 0) { records.bestStepDay = (day, steps) }
        }
        var weekSteps: [String: Int] = [:]
        for (day, steps) in stepsByDay {
            guard let start = PeriodCalendar.weekDays(containing: day, firstWeekday: firstWeekday).first else { continue }
            weekSteps[start, default: 0] += steps
        }
        for start in weekSteps.keys.sorted() {
            let steps = weekSteps[start] ?? 0
            if steps > (records.bestStepWeek?.steps ?? 0) { records.bestStepWeek = (start, steps) }
        }
        var weekWorkouts: [String: Int] = [:]
        for day in workoutDays {
            guard let start = PeriodCalendar.weekDays(containing: day, firstWeekday: firstWeekday).first else { continue }
            weekWorkouts[start, default: 0] += 1
        }
        for start in weekWorkouts.keys.sorted() {
            let count = weekWorkouts[start] ?? 0
            if count > (records.mostWorkoutsWeek?.count ?? 0) { records.mostWorkoutsWeek = (start, count) }
        }
        return records
    }

    /// True when `today` beats every earlier day (not just ties it) and there is an earlier day to beat.
    public static func isNewStepRecord(stepsByDay: [String: Int], today: String) -> Bool {
        guard let todaySteps = stepsByDay[today], todaySteps > 0 else { return false }
        let earlier = stepsByDay.filter { $0.key < today }.values
        guard let previousBest = earlier.max(), previousBest > 0 else { return false }
        return todaySteps > previousBest
    }
}
