import Foundation
import WhoopStore

// MARK: - Training history over months and years
//
// The Training Load screen answers "how does this week compare with your usual". The history view
// answers the longer question — what the last months or years looked like — from the same daily series
// and the same `LaneEngine` bands, so a week in the history reads exactly as it read at the time.
//
// Each lane keeps its own unit, also here: periods are summed within a lane and never across lanes.
//
// Three kinds of day are kept apart, because only one of them is training:
//   • KNOWN — a measured load, zero on a rest day;
//   • UNKNOWN — training the data could not price (no usable heart rate, an unrated session). Never
//     counted as rest: a gap in measurement would otherwise read as a drop in training;
//   • UNRECORDED — before the lane's history began, or after its reading day (an unfinished today).
//     Neither rest nor a gap: there was nothing to measure yet.
//
// Resolution follows the span: days up to three months, weeks up to two years, months beyond. A bar per
// day over ten years would be thousands of slivers nobody can read, and a month over three months would
// hide the week the question is usually about.

/// How far back a history view reaches.
public enum TrainingHistorySpan: String, CaseIterable, Sendable, Codable {
    case threeMonths, oneYear, fiveYears, all

    /// Days the span covers, nil for the whole history.
    public var days: Int? {
        switch self {
        case .threeMonths: return 92
        case .oneYear: return 365
        case .fiveYears: return 1_826
        case .all: return nil
        }
    }
}

/// What one bar stands for.
public enum TrainingHistoryResolution: String, Sendable, Codable {
    case day, week, month

    /// The longest window still drawn in days.
    public static let dayLimit = 92
    /// The longest window still drawn in weeks.
    public static let weekLimit = 731

    public static func forWindow(days: Int) -> TrainingHistoryResolution {
        if days <= dayLimit { return .day }
        if days <= weekLimit { return .week }
        return .month
    }
}

/// The days a history view covers and how it groups them.
public struct TrainingHistoryRange: Equatable, Sendable {
    /// First day of the first period (a Monday for weeks, the 1st for months).
    public let first: String
    /// Last day shown, inclusive.
    public let last: String
    public let resolution: TrainingHistoryResolution

    public init(first: String, last: String, resolution: TrainingHistoryResolution) {
        self.first = first
        self.last = last
        self.resolution = resolution
    }
}

/// One bar's days, inclusive at both ends. The last period may be cut short by the range's end.
public struct TrainingHistoryPeriod: Equatable, Sendable, Hashable {
    public let start: String
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }

    public var days: Int { TrainingHistory.daysBetween(start, end) + 1 }

    public func contains(_ day: String) -> Bool { day >= start && day <= end }
}

/// One lane over one period.
public struct TrainingHistoryLanePeriod: Equatable, Sendable {
    public let period: TrainingHistoryPeriod
    /// The known days' summed load, in the lane's own unit. Nil when no day of the period was known.
    public let total: Double?
    public let knownDays: Int
    /// Days with training the data could not price.
    public let unknownDays: Int
    /// Days before the lane's history began or after its reading day.
    public let unrecordedDays: Int
    /// The lane's usual for a period this long: the mean known daily load of the 42 days ending on the
    /// period's last recorded day, times the period's recorded days. Nil with fewer than 21 known days.
    public let level: Double?
    /// The band at the period's last recorded day, as `LaneEngine` read it then. Nil for Session Load.
    public let band: RelativeLoadBand?
    /// Sessions the figure rests on, and the sessions there were — the rating quota for Session Load.
    public let measured: Int?
    public let possible: Int?

    public init(period: TrainingHistoryPeriod, total: Double?, knownDays: Int, unknownDays: Int,
                unrecordedDays: Int, level: Double?, band: RelativeLoadBand?, measured: Int?, possible: Int?) {
        self.period = period
        self.total = total
        self.knownDays = knownDays
        self.unknownDays = unknownDays
        self.unrecordedDays = unrecordedDays
        self.level = level
        self.band = band
        self.measured = measured
        self.possible = possible
    }

    /// Share of the recorded days that were known, nil when none was recorded.
    public var coverage: Double? {
        let recorded = knownDays + unknownDays
        return recorded > 0 ? Double(knownDays) / Double(recorded) : nil
    }
}

/// A value per period beside the load — e1RM or VO₂max. Nil where the period had no reading.
public struct TrainingHistoryValue: Equatable, Sendable {
    public let period: TrainingHistoryPeriod
    public let value: Double?

    public init(period: TrainingHistoryPeriod, value: Double?) {
        self.period = period
        self.value = value
    }
}

public enum TrainingHistory {

    /// Days behind the long-term level line — the chronic horizon used for training load since Banister.
    public static let levelDays = 42
    /// Known days the level needs inside its 42.
    public static let levelMinimumKnownDays = 21
    /// Lifts drawn above the strength lane by default.
    public static let defaultLiftCount = 3

    // MARK: - Days

    /// Whole days from `a` to `b` (negative when `b` is earlier).
    public static func daysBetween(_ a: String, _ b: String) -> Int {
        guard let (ay, am, ad) = WeeklyDigestEngine.parseYMD(a),
              let (by, bm, bd) = WeeklyDigestEngine.parseYMD(b) else { return 0 }
        return WeeklyDigestEngine.julianDayNumber(by, bm, bd) - WeeklyDigestEngine.julianDayNumber(ay, am, ad)
    }

    static func firstOfMonth(_ day: String) -> String {
        guard let (y, m, _) = WeeklyDigestEngine.parseYMD(day) else { return day }
        return WeeklyDigestEngine.formatYMD(y, m, 1)
    }

    static func lastOfMonth(_ day: String) -> String {
        guard let (y, m, _) = WeeklyDigestEngine.parseYMD(day) else { return day }
        return WeeklyDigestEngine.formatYMD(y, m, WeeklyDigestEngine.daysInMonth(y, m))
    }

    // MARK: - Range and periods

    /// The range a span shows, ending on `end`. `.all` starts at `earliest` (the first day any lane holds
    /// data); without data it is one day long. The first day is moved back to its period's start, so no
    /// bar at the left edge stands for a fraction of a week or month.
    public static func range(span: TrainingHistorySpan, end: String, earliest: String?) -> TrainingHistoryRange {
        let start: String
        if let days = span.days {
            start = WeeklyDigestEngine.addDays(end, -(days - 1))
        } else {
            start = min(earliest ?? end, end)
        }
        let resolution = TrainingHistoryResolution.forWindow(days: daysBetween(start, end) + 1)
        let aligned: String
        switch resolution {
        case .day: aligned = start
        case .week: aligned = WeeklyDigestEngine.mondayOfWeek(containing: start) ?? start
        case .month: aligned = firstOfMonth(start)
        }
        return TrainingHistoryRange(first: aligned, last: end, resolution: resolution)
    }

    /// The periods of a range, oldest first.
    public static func periods(_ range: TrainingHistoryRange) -> [TrainingHistoryPeriod] {
        guard range.first <= range.last else { return [] }
        var result: [TrainingHistoryPeriod] = []
        var cursor = range.first
        while cursor <= range.last {
            let natural: String
            switch range.resolution {
            case .day: natural = cursor
            case .week: natural = WeeklyDigestEngine.addDays(cursor, 6)
            case .month: natural = lastOfMonth(cursor)
            }
            let end = min(natural, range.last)
            result.append(TrainingHistoryPeriod(start: cursor, end: end))
            cursor = WeeklyDigestEngine.addDays(natural, 1)
        }
        return result
    }

    /// The period holding `day`, if the range shows it.
    public static func period(containing day: String, in periods: [TrainingHistoryPeriod]) -> TrainingHistoryPeriod? {
        periods.first { $0.contains(day) }
    }

    // MARK: - A lane

    /// One lane over the periods.
    ///
    /// - Parameters:
    ///   - dailyByDay: the lane's daily load; a recorded day without an entry was a rest day.
    ///   - unknownDays: days with training the data could not price.
    ///   - historyStart: the lane's first recorded day; earlier days are unrecorded, not rest.
    ///   - through: the lane's reading day (`LaneEngine.readingDay`); later days are unrecorded.
    ///   - bandLane: the lane whose `LaneEngine` bands to read, with its activity; nil for Session Load.
    ///   - measuredByDay / possibleByDay: session counts behind the figure, for a coverage quota.
    public static func lane(dailyByDay: [String: Double], unknownDays: Set<String> = [],
                            historyStart: String?, through: String,
                            periods: [TrainingHistoryPeriod],
                            bandLane: (kind: TrainingLaneKind, activity: LaneActivity)? = nil,
                            measuredByDay: [String: Int]? = nil,
                            possibleByDay: [String: Int]? = nil) -> [TrainingHistoryLanePeriod] {
        let recordedEnds: [String?] = periods.map { period in
            guard let historyStart, period.end >= historyStart, period.start <= through else { return nil }
            return min(period.end, through)
        }
        var bandByDay: [String: RelativeLoadBand] = [:]
        if let bandLane {
            let days = Array(Set(recordedEnds.compactMap { $0 })).sorted()
            let readings = LaneEngine.readings(dailyByDay: dailyByDay, unknownDays: unknownDays,
                                               activity: bandLane.activity, lane: bandLane.kind, days: days)
            for (day, reading) in zip(days, readings) {
                if let band = reading.band { bandByDay[day] = band }
            }
        }
        return zip(periods, recordedEnds).map { period, recordedEnd in
            var known = 0, unknown = 0, unrecorded = 0
            var total = 0.0
            var measured = 0, possible = 0
            var cursor = period.start
            while cursor <= period.end {
                if let historyStart, cursor >= historyStart, cursor <= through {
                    if unknownDays.contains(cursor) {
                        unknown += 1
                    } else {
                        known += 1
                        total += dailyByDay[cursor] ?? 0
                    }
                    measured += measuredByDay?[cursor] ?? 0
                    possible += possibleByDay?[cursor] ?? 0
                } else {
                    unrecorded += 1
                }
                cursor = WeeklyDigestEngine.addDays(cursor, 1)
            }
            let level = recordedEnd.flatMap {
                levelPerDay(dailyByDay: dailyByDay, unknownDays: unknownDays, historyStart: historyStart,
                            through: $0)
            }.map { $0 * Double(known + unknown) }
            return TrainingHistoryLanePeriod(
                period: period, total: known > 0 ? total : nil, knownDays: known, unknownDays: unknown,
                unrecordedDays: unrecorded, level: level,
                band: recordedEnd.flatMap { bandByDay[$0] },
                measured: measuredByDay == nil ? nil : measured,
                possible: possibleByDay == nil ? nil : possible)
        }
    }

    /// The mean known daily load over the 42 days ending on `day`, nil with fewer than 21 known days.
    static func levelPerDay(dailyByDay: [String: Double], unknownDays: Set<String>, historyStart: String?,
                            through day: String) -> Double? {
        guard let historyStart else { return nil }
        var known = 0
        var total = 0.0
        var cursor = day
        for _ in 0..<levelDays {
            if cursor < historyStart { break }
            if !unknownDays.contains(cursor) {
                known += 1
                total += dailyByDay[cursor] ?? 0
            }
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return known >= levelMinimumKnownDays ? total / Double(known) : nil
    }

    // MARK: - Values beside the load

    /// The highest reading per period — the right summary for a session-best e1RM.
    public static func maxPerPeriod(_ points: [(day: String, value: Double)],
                                    periods: [TrainingHistoryPeriod]) -> [TrainingHistoryValue] {
        summarise(points, periods: periods) { $0.max() }
    }

    /// The mean reading per period — for VO₂max, whose estimates arrive weekly.
    public static func meanPerPeriod(_ points: [(day: String, value: Double)],
                                     periods: [TrainingHistoryPeriod]) -> [TrainingHistoryValue] {
        summarise(points, periods: periods) { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) }
    }

    private static func summarise(_ points: [(day: String, value: Double)], periods: [TrainingHistoryPeriod],
                                  _ reduce: ([Double]) -> Double?) -> [TrainingHistoryValue] {
        guard let first = periods.first?.start, let last = periods.last?.end else { return [] }
        let sorted = points.filter { $0.day >= first && $0.day <= last }.sorted { $0.day < $1.day }
        var index = 0
        return periods.map { period in
            var values: [Double] = []
            while index < sorted.count, sorted[index].day <= period.end {
                if sorted[index].day >= period.start { values.append(sorted[index].value) }
                index += 1
            }
            return TrainingHistoryValue(period: period, value: reduce(values))
        }
    }

    // MARK: - Lifts

    /// The exercises trained in the most sessions between `from` and `through`, most first, then by id so
    /// the order never depends on iteration. Only exercises with at least one e1RM are counted: a lift
    /// with no estimate would draw no line.
    public static func mostTrainedTemplates(workouts: [HevyWorkout], templates: [String: HevyExerciseTemplate],
                                            from: String, through: String, tzOffsetSeconds: Int = 0,
                                            limit: Int = defaultLiftCount) -> [String] {
        var sessions: [String: Int] = [:]
        for workout in workouts {
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)
            guard day >= from, day <= through else { continue }
            var counted = Set<String>()
            for exercise in workout.exercises {
                guard let id = exercise.templateId, !counted.contains(id) else { continue }
                let hasEstimate = exercise.workingSets.contains {
                    OneRepMax.forSet($0, template: templates[id]) != nil
                }
                guard hasEstimate else { continue }
                counted.insert(id)
                sessions[id, default: 0] += 1
            }
        }
        return sessions.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(\.key)
    }

    /// One lift's session-best e1RM, highest per period.
    public static func liftSeries(templateId: String, workouts: [HevyWorkout],
                                  templates: [String: HevyExerciseTemplate],
                                  periods: [TrainingHistoryPeriod], tzOffsetSeconds: Int = 0) -> [TrainingHistoryValue] {
        let points = StrengthSession.exerciseHistory(templateId: templateId, workouts: workouts,
                                                     templates: templates, tzOffsetSeconds: tzOffsetSeconds)
            .compactMap { point in point.bestE1RMKg.map { (day: point.day, value: $0) } }
        return maxPerPeriod(points, periods: periods)
    }
}
