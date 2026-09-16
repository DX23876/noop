import Foundation
import WhoopStore

/// Bounded, window-scoped facts for the Strength overview. It deliberately contains no relative
/// training-load interpretation: that belongs to Training Load, while this type answers how often,
/// how long and how much resistance training was recorded in the selected period.
public struct StrengthOverview: Equatable, Sendable {
    public struct PersonalRecord: Identifiable, Equatable, Sendable {
        public let exerciseId: String
        public let exerciseTitle: String
        public let workoutId: String
        public let timestamp: Int
        public let estimatedOneRepMaxKg: Double

        public var id: String { "\(workoutId)|\(exerciseId)" }
    }

    public let sessionCount: Int
    public let trainingDayCount: Int
    public let workingSetCount: Int
    public let ratedSetCount: Int
    public let volumeLoadKg: Double
    public let volumeSetCount: Int
    public let durationSeconds: Int
    public let durationSessionCount: Int
    public let sessionsPerWeek: Double
    /// Mean recorded RPE of the rated working sets, or nil when none carries a rating. An unrated set
    /// never enters as an assumed effort; `rpeCoverage` states how much of the work this describes.
    public let averageRPE: Double?
    /// Calendar weeks, aligned to the wearer's week start, that contain at least one session.
    public let activeWeekCount: Int
    /// Calendar weeks from the first session in the window through the window end. Counting from the
    /// first session keeps a long all-time window from reading as years of missed training.
    public let observedWeekCount: Int
    /// The longest run of consecutive active weeks inside the window.
    public let longestActiveWeekStreak: Int
    public let personalRecords: [PersonalRecord]

    public var rpeCoverage: Double {
        workingSetCount > 0 ? Double(ratedSetCount) / Double(workingSetCount) : 0
    }

    public var durationCoverage: Double {
        sessionCount > 0 ? Double(durationSessionCount) / Double(sessionCount) : 0
    }

    public var weeklyConsistency: Double {
        observedWeekCount > 0 ? Double(activeWeekCount) / Double(observedWeekCount) : 0
    }

    /// `firstWeekday` follows `Calendar`: 1 = Sunday, 2 = Monday.
    public static func calculate(workouts: [HevyWorkout],
                                 templates: [String: HevyExerciseTemplate],
                                 from: Int, to: Int,
                                 tzOffsetSeconds: Int = 0,
                                 firstWeekday: Int = 2) -> Self {
        let selected = workouts.filter { $0.startTs >= from && $0.startTs <= to }
        var workingSets = 0
        var ratedSets = 0
        var rpeTotal = 0.0
        var volumeSets = 0
        var volume = 0.0
        var duration = 0
        var durationSessions = 0

        for workout in selected {
            if workout.endTs > workout.startTs {
                duration += workout.endTs - workout.startTs
                durationSessions += 1
            }
            for set in workout.exercises.flatMap(\.workingSets) {
                workingSets += 1
                if let rpe = set.rpe {
                    ratedSets += 1
                    rpeTotal += rpe
                }
                if let value = set.volumeLoadKg {
                    volume += value
                    volumeSets += 1
                }
            }
        }

        let activeWeeks = Set(selected.map {
            weekIndex($0.startTs, tzOffsetSeconds: tzOffsetSeconds, firstWeekday: firstWeekday)
        })
        var observedWeeks = 0
        if let firstSession = selected.map(\.startTs).min() {
            let firstWeek = weekIndex(firstSession, tzOffsetSeconds: tzOffsetSeconds, firstWeekday: firstWeekday)
            let lastWeek = weekIndex(max(to, firstSession), tzOffsetSeconds: tzOffsetSeconds,
                                     firstWeekday: firstWeekday)
            observedWeeks = lastWeek - firstWeek + 1
        }
        var longestStreak = 0
        var currentStreak = 0
        var previousWeek: Int?
        for week in activeWeeks.sorted() {
            currentStreak = previousWeek.map { week == $0 + 1 } == true ? currentStreak + 1 : 1
            longestStreak = max(longestStreak, currentStreak)
            previousWeek = week
        }

        let seconds = max(1, to - from + 1)
        let weeks = max(1.0 / 7.0, Double(seconds) / (7 * 86_400))
        return Self(
            sessionCount: selected.count,
            trainingDayCount: StrengthSession.dayKeys(selected, tzOffsetSeconds: tzOffsetSeconds).count,
            workingSetCount: workingSets,
            ratedSetCount: ratedSets,
            volumeLoadKg: volume,
            volumeSetCount: volumeSets,
            durationSeconds: duration,
            durationSessionCount: durationSessions,
            sessionsPerWeek: Double(selected.count) / weeks,
            averageRPE: ratedSets > 0 ? rpeTotal / Double(ratedSets) : nil,
            activeWeekCount: activeWeeks.count,
            observedWeekCount: observedWeeks,
            longestActiveWeekStreak: longestStreak,
            personalRecords: recordTimeline(workouts: selected, templates: templates))
    }

    /// Local calendar-week number of `ts`. 1970-01-01 was a Thursday, so the weekday of epoch day `d`
    /// (0 = Sunday … 6 = Saturday) is `(d + 4) mod 7`; the week begins on the most recent `firstWeekday`.
    static func weekIndex(_ ts: Int, tzOffsetSeconds: Int, firstWeekday: Int) -> Int {
        let day = floorDivide(ts + tzOffsetSeconds, 86_400)
        let startWeekday = ((firstWeekday - 1) % 7 + 7) % 7
        let daysSinceWeekStart = ((day + 4 - startWeekday) % 7 + 7) % 7
        return floorDivide(day - daysSinceWeekStart, 7)
    }

    private static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
    }

    /// Every exercise contributes at most one point per session. A point becomes a record only when it
    /// exceeds everything previously observed for that exercise; a later lower set never erases it.
    private static func recordTimeline(workouts: [HevyWorkout],
                                       templates: [String: HevyExerciseTemplate]) -> [PersonalRecord] {
        var bestByExercise: [String: Double] = [:]
        var records: [PersonalRecord] = []
        for workout in workouts.sorted(by: { $0.startTs < $1.startTs }) {
            for exercise in workout.exercises {
                let exerciseId = exercise.templateId
                    ?? "title:\(exercise.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                let template = exercise.templateId.flatMap { templates[$0] }
                guard let sessionBest = exercise.workingSets.compactMap({
                    OneRepMax.forSet($0, template: template)
                }).max(), sessionBest > (bestByExercise[exerciseId] ?? 0) else { continue }
                bestByExercise[exerciseId] = sessionBest
                records.append(.init(exerciseId: exerciseId, exerciseTitle: exercise.title,
                                     workoutId: workout.id, timestamp: workout.startTs,
                                     estimatedOneRepMaxKg: sessionBest))
            }
        }
        return records.sorted { $0.timestamp > $1.timestamp }
    }
}
