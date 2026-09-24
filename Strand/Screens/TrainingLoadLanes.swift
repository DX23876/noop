import Foundation
import StrandAnalytics
import WhoopStore

/// The Strength and Cardio lane readings, computed as of any day.
///
/// Training Load, Cardio and Strength all show "this lane against your usual", and tapping from one to
/// another must never change the figure. So there is exactly one computation, and the only thing a
/// screen chooses is the day it is read through.
enum TrainingLoadLanes {
    /// History a reading needs before its day: the days `LaneEngine` reads (each day's eight-week
    /// comparison, the hysteresis warm-up and the longest below-usual run), plus the 28 days of earlier
    /// ratings the first of those days weights its unrated sets with. Data older than this does not move
    /// a reading.
    static let lookbackDays = LaneEngine.dependencyDays + TrainingLoad.baselineWindow

    struct CardioSeries: Sendable {
        let byDay: [String: Double]
        /// Days that held training the data could not price. They leave both comparison windows rather
        /// than counting as rest, so a gap in the measurement is never reported as a drop in training.
        let unknownDays: Set<String>
        let measured: Bool
        /// Cardio sessions per day and their minutes — what the lane's guards read.
        let activity: LaneActivity
    }

    static func strengthByDay(_ workouts: [HevyWorkout], tzOffsetSeconds: Int) -> [String: Double] {
        StrengthSession.weightedSetsByDay(workouts, tzOffsetSeconds: tzOffsetSeconds)
    }

    static func cardioSeries(sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                             tzOffsetSeconds: Int) -> CardioSeries {
        let series = TrainingLoadModel.cardioDailyLoad(sessions: sessions, loads: resolution.loads,
                                                       duplicates: resolution.duplicateSessionIds,
                                                       tzOffsetSeconds: tzOffsetSeconds)
        return CardioSeries(byDay: series.byDay, unknownDays: series.unknownDays, measured: series.measured,
                            activity: cardioActivity(sessions: sessions, duplicates: resolution.duplicateSessionIds,
                                                     tzOffsetSeconds: tzOffsetSeconds))
    }

    /// Strength sessions per day and their minutes, for the lane's guards.
    static func strengthActivity(_ workouts: [HevyWorkout], tzOffsetSeconds: Int) -> LaneActivity {
        var sessions: [String: Int] = [:]
        var minutes: [String: Double] = [:]
        for workout in workouts {
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)
            sessions[day, default: 0] += 1
            minutes[day, default: 0] += Double(max(0, workout.endTs - workout.startTs)) / 60
        }
        return LaneActivity(sessionsByDay: sessions, minutesByDay: minutes)
    }

    /// Cardio sessions per day and their minutes, for the lane's guards: every non-strength session long
    /// enough to be priced, whether or not its heart rate could be, and each bout counted once.
    static func cardioActivity(sessions: [UnifiedTrainingSession], duplicates: Set<String>,
                               tzOffsetSeconds: Int) -> LaneActivity {
        var count: [String: Int] = [:]
        var minutes: [String: Double] = [:]
        for session in sessions where session.kind != .strength && !duplicates.contains(session.id) {
            let window = session.row.endTs - session.row.startTs
            guard window >= Repository.cardioLoadMinimumSeconds else { continue }
            let day = AnalyticsEngine.dayString(session.row.startTs, offsetSec: tzOffsetSeconds)
            count[day, default: 0] += 1
            minutes[day, default: 0] += (session.row.durationS ?? Double(window)) / 60
        }
        return LaneActivity(sessionsByDay: count, minutesByDay: minutes)
    }

    static func strengthLane(workouts: [HevyWorkout], byDay: [String: Double], through day: String,
                             tzOffsetSeconds: Int) -> TrainingLoadModel.Lane {
        let recent = inLastSeven(workouts, through: day, tzOffsetSeconds: tzOffsetSeconds) { $0.startTs }
        let pooled = StrengthSession.strengthLoad(recent)
        let reading = LaneEngine.reading(dailyByDay: byDay,
                                         activity: strengthActivity(workouts, tzOffsetSeconds: tzOffsetSeconds),
                                         lane: .strength, through: day)
        return TrainingLoadModel.Lane(
            sevenDayTotal: lastSeven(byDay, through: day),
            sevenDayWorkingSets: recent.flatMap { $0.exercises.flatMap(\.workingSets) }.count,
            trend: reading.trend,
            relative: reading.relative,
            isLowerBound: false,
            distribution: TrainingLoad.distribution(dailyByDay: byDay, through: day),
            weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: byDay, through: day),
            measuredCount: pooled.ratedSets,
            possibleCount: pooled.workingSets,
            reading: reading)
    }

    static func cardioLane(sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                           series: CardioSeries, through day: String,
                           tzOffsetSeconds: Int) -> TrainingLoadModel.Lane {
        // A session skipped because another one already priced the same minutes is NOT a session with
        // missing heart rate, so it must not widen the coverage denominator.
        let recent = inLastSeven(sessions, through: day, tzOffsetSeconds: tzOffsetSeconds) { $0.row.startTs }
            .filter {
                ($0.row.endTs - $0.row.startTs) >= Repository.cardioLoadMinimumSeconds
                    && !resolution.duplicateSessionIds.contains($0.id)
            }
        let reading = LaneEngine.reading(dailyByDay: series.byDay, unknownDays: series.unknownDays,
                                         activity: series.activity, lane: .cardio, through: day)
        return TrainingLoadModel.Lane(
            sevenDayTotal: lastSeven(series.byDay, through: day),
            sevenDayWorkingSets: 0,
            trend: reading.trend,
            relative: reading.relative,
            isLowerBound: lastSevenContainsUnknown(series.unknownDays, through: day),
            distribution: TrainingLoad.distribution(dailyByDay: series.byDay, through: day,
                                                    unknownDays: series.unknownDays),
            weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: series.byDay, through: day,
                                                    unknownDays: series.unknownDays),
            measuredCount: recent.filter { resolution.loads[$0.id] != nil }.count,
            possibleCount: recent.count,
            reading: reading)
    }

    /// The 56 daily readings ending at `day`, per lane — the same readings the hero shows, day by day,
    /// so the chart's line and colours can never disagree with the label above them. A lane the caller
    /// did not read stays nil.
    static func ratios(strengthByDay: [String: Double]?, strengthActivity: LaneActivity? = nil,
                       cardio: CardioSeries?, through day: String) -> [TrainingLoadModel.RatioPoint] {
        let days = (0..<56).reversed().map { WeeklyDigestEngine.addDays(day, -$0) }
        let strength = strengthByDay.map {
            LaneEngine.readings(dailyByDay: $0, activity: strengthActivity ?? .none, lane: .strength, days: days)
        }
        let cardio = cardio.map {
            LaneEngine.readings(dailyByDay: $0.byDay, unknownDays: $0.unknownDays, activity: $0.activity,
                                lane: .cardio, days: days)
        }
        return days.indices.map { index in
            TrainingLoadModel.RatioPoint(day: days[index],
                                         strength: strength?[index].trend?.ratio,
                                         cardio: cardio?[index].trend?.ratio,
                                         strengthBand: strength?[index].band,
                                         cardioBand: cardio?[index].band)
        }
    }

    /// The Strength and Cardio lanes as Readiness reads them, through the same reading days the Training
    /// Load screen uses (`LaneEngine.readingDay`), so Today's load signal and the screen's hero can never
    /// name two different bands. Session Load stays out: it is not a heart-rate or set measure and has
    /// no guard of its own (Q18).
    static func readinessContext(strengthWorkouts: [HevyWorkout], cardio: CardioSeries, today: String,
                                 tzOffsetSeconds: Int) -> ReadinessLoadContext {
        let strengthByDay = strengthByDay(strengthWorkouts, tzOffsetSeconds: tzOffsetSeconds)
        let strengthActivity = strengthActivity(strengthWorkouts, tzOffsetSeconds: tzOffsetSeconds)
        let strengthDay = LaneEngine.readingDay(today: today,
                                                hasActivityToday: (strengthActivity.sessionsByDay[today] ?? 0) > 0)
        let cardioDay = LaneEngine.readingDay(today: today,
                                              hasActivityToday: (cardio.activity.sessionsByDay[today] ?? 0) > 0)
        let strength = LaneEngine.reading(dailyByDay: strengthByDay, activity: strengthActivity,
                                          lane: .strength, through: strengthDay)
        let cardioReading = LaneEngine.reading(dailyByDay: cardio.byDay, unknownDays: cardio.unknownDays,
                                               activity: cardio.activity, lane: .cardio, through: cardioDay)
        return ReadinessLoadContext(lanes: [
            ReadinessLoadContext.Lane(kind: .strength, reading: strength, dailyByDay: strengthByDay),
            ReadinessLoadContext.Lane(kind: .cardio, reading: cardioReading, dailyByDay: cardio.byDay,
                                      unknownDays: cardio.unknownDays)
        ])
    }

    /// The day a week is read through: its Sunday, or — while the week is still running — today once
    /// something was logged today, otherwise yesterday (`LaneEngine.readingDay`).
    static func readingDay(monday: String, today: String, hasActivityToday: Bool) -> String {
        min(WeeklyDigestEngine.addDays(monday, 6),
            LaneEngine.readingDay(today: today, hasActivityToday: hasActivityToday))
    }

    static func inLastSeven<T>(_ items: [T], through day: String, tzOffsetSeconds: Int,
                               start: (T) -> Int) -> [T] {
        let cutoff = WeeklyDigestEngine.addDays(day, -6)
        return items.filter {
            let itemDay = AnalyticsEngine.dayString(start($0), offsetSec: tzOffsetSeconds)
            return itemDay >= cutoff && itemDay <= day
        }
    }

    static func lastSeven(_ values: [String: Double], through day: String) -> Double {
        var total = 0.0
        var cursor = day
        for _ in 0..<7 {
            total += values[cursor] ?? 0
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return total
    }

    static func lastSevenContainsUnknown(_ unknownDays: Set<String>, through day: String) -> Bool {
        var cursor = day
        for _ in 0..<7 {
            if unknownDays.contains(cursor) { return true }
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return false
    }
}
