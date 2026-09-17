import Foundation
import StrandAnalytics
import WhoopStore

/// The Strength and Cardio lane readings, computed as of any day.
///
/// Training Load, Cardio and Strength all show "this lane against your usual", and tapping from one to
/// another must never change the figure. So there is exactly one computation, and the only thing a
/// screen chooses is the day it is read through.
enum TrainingLoadLanes {
    /// History a reading needs before its day: the eight-week personal comparison, plus the 28 days of
    /// earlier ratings the first of those days weights its unrated sets with. Data older than this does
    /// not move a reading.
    static let lookbackDays = TrainingLoad.personalBaselineWeeks * TrainingLoad.recentWindow
        + TrainingLoad.baselineWindow

    struct CardioSeries: Sendable {
        let byDay: [String: Double]
        /// Days that held training the data could not price. They leave both comparison windows rather
        /// than counting as rest, so a gap in the measurement is never reported as a drop in training.
        let unknownDays: Set<String>
        let measured: Bool
    }

    static func strengthByDay(_ workouts: [HevyWorkout], tzOffsetSeconds: Int) -> [String: Double] {
        StrengthSession.weightedSetsByDay(workouts, tzOffsetSeconds: tzOffsetSeconds)
    }

    static func cardioSeries(sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                             tzOffsetSeconds: Int) -> CardioSeries {
        let series = TrainingLoadModel.cardioDailyLoad(sessions: sessions, loads: resolution.loads,
                                                       duplicates: resolution.duplicateSessionIds,
                                                       tzOffsetSeconds: tzOffsetSeconds)
        return CardioSeries(byDay: series.byDay, unknownDays: series.unknownDays, measured: series.measured)
    }

    static func strengthLane(workouts: [HevyWorkout], byDay: [String: Double], through day: String,
                             tzOffsetSeconds: Int) -> TrainingLoadModel.Lane {
        let recent = inLastSeven(workouts, through: day, tzOffsetSeconds: tzOffsetSeconds) { $0.startTs }
        let pooled = StrengthSession.strengthLoad(recent)
        let relative = TrainingLoad.relativeLoad(dailyByDay: byDay, through: day)
        return TrainingLoadModel.Lane(
            sevenDayTotal: lastSeven(byDay, through: day),
            sevenDayWorkingSets: recent.flatMap { $0.exercises.flatMap(\.workingSets) }.count,
            trend: relative.trend,
            relative: relative,
            isLowerBound: false,
            distribution: TrainingLoad.distribution(dailyByDay: byDay, through: day),
            weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: byDay, through: day),
            measuredCount: pooled.ratedSets,
            possibleCount: pooled.workingSets,
            status: relativeStatus(relative))
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
        let relative = TrainingLoad.relativeLoad(dailyByDay: series.byDay, through: day,
                                                 unknownDays: series.unknownDays)
        return TrainingLoadModel.Lane(
            sevenDayTotal: lastSeven(series.byDay, through: day),
            sevenDayWorkingSets: 0,
            trend: relative.trend,
            relative: relative,
            isLowerBound: lastSevenContainsUnknown(series.unknownDays, through: day),
            distribution: TrainingLoad.distribution(dailyByDay: series.byDay, through: day,
                                                    unknownDays: series.unknownDays),
            weekOverWeek: TrainingLoad.weekOverWeek(dailyByDay: series.byDay, through: day,
                                                    unknownDays: series.unknownDays),
            measuredCount: recent.filter { resolution.loads[$0.id] != nil }.count,
            possibleCount: recent.count,
            status: relativeStatus(relative))
    }

    /// The 56 daily ratios ending at `day`, per lane. A lane the caller did not read stays nil.
    static func ratios(strengthByDay: [String: Double]?, cardio: CardioSeries?,
                       through day: String) -> [TrainingLoadModel.RatioPoint] {
        var ratios: [TrainingLoadModel.RatioPoint] = []
        var ratioDay = WeeklyDigestEngine.addDays(day, -55)
        for _ in 0..<56 {
            ratios.append(TrainingLoadModel.RatioPoint(
                day: ratioDay,
                strength: strengthByDay.flatMap { TrainingLoad.trend(dailyByDay: $0, through: ratioDay)?.ratio },
                cardio: cardio.flatMap {
                    TrainingLoad.trend(dailyByDay: $0.byDay, through: ratioDay, unknownDays: $0.unknownDays)?.ratio
                }))
            ratioDay = WeeklyDigestEngine.addDays(ratioDay, 1)
        }
        return ratios
    }

    /// The day a week is read through: its Sunday, or today while the week is still running.
    static func readingDay(monday: String, today: String) -> String {
        min(WeeklyDigestEngine.addDays(monday, 6), today)
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

    /// Adapts the neutral relative-load reading to the existing ring renderer. The legacy case names
    /// are not presented to the wearer; `TrainingStatusVisuals` labels these as relative-load bands.
    static func relativeStatus(_ reading: RelativeLoadReading) -> LaneStatus? {
        guard let trend = reading.trend else { return nil }
        let relativeBand: RelativeLoadBand = reading.band ?? {
            if trend.percentChange < -15 { return .below }
            if trend.percentChange <= 15 { return .usual }
            if trend.percentChange <= 30 { return .higher }
            return .muchHigher
        }()
        let legacyStatus: TrainingStatus
        let legacyBand: TrainingLoadBand
        switch relativeBand {
        case .below: legacyStatus = .detraining; legacyBand = .below
        case .usual: legacyStatus = .maintaining; legacyBand = .maintaining
        case .higher: legacyStatus = .productive; legacyBand = .productive
        case .muchHigher: legacyStatus = .overreaching; legacyBand = .above
        }
        return LaneStatus(status: legacyStatus, ratio: trend.ratio, band: legacyBand,
                          followsRecentHighPhase: false, usedStrengthResponse: false,
                          usedRecovery: false)
    }
}
