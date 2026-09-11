import Foundation
import WhoopStore

// MARK: - Is this training doing anything? A status per lane
//
// `TrainingLoad` answers "how much, compared with your usual". This file answers the question people
// actually ask of that number: is it too much, too little, or about right. It does so in the terms the
// two lanes can honestly support, and the two lanes are NOT treated alike.
//
// CARDIO follows Polar's Cardio Load Status, unchanged. Polar compares Strain (the rolling seven-day mean
// of daily cardio load) with Tolerance (the rolling 28-day mean) and names four states by the ratio:
// below 0.8 detraining/recovering, 0.8–1.0 maintaining, 1.0–1.3 productive, above 1.3 overreaching
// (Polar Training Load Pro white paper; Polar support). NOOP's cardio lane is the same construction —
// a seven-day mean of TRIMP-derived Effort against a mean of up to 28 days, rest days as zeros — so the
// thresholds transfer without re-interpretation. Polar computes the status from cardio load ONLY.
//
// STRENGTH is where nobody has published a validated status. Polar has no set-based strength load at
// all (its Muscle Load needs running or cycling power); Garmin's load is heart-rate EPOC; WHOOP folds an
// unvalidated wrist-motion estimate into Strain; Apple asks for a manual effort rating. The 2025
// ACWR meta-analysis (22 studies) contains no resistance-training study, and even for the sports it
// covers it does not call 0.8–1.3 reliably safe. So the ratio alone is not allowed to call a strength
// block "productive". The status also asks whether anything improved — the idea Garmin uses, where
// "productive" needs load AND a rising VO2max. For lifting, the improvement that can be measured is the
// estimated one-rep max of the lifts being trained: `StrengthProgress.e1rmTrend`, the same robust line
// the exercise card draws, restricted to the last six weeks. And above 1.3 it asks the body, through the
// recovery signals `ReadinessEngine` already reads (HRV, resting HR, respiratory rate).
//
// Two rules here are NOOP's own and are named as such wherever they are shown:
//   • "Recovering" rather than "detraining" when the ratio has dropped below 0.8 within two weeks of a
//     productive or overreaching phase. Polar distinguishes the two but does not publish how.
//   • The strength decision table below, and the aggregation of several lifts into one direction.
//
// Nothing here is stored or feeds a score. It is a read-time label over figures the screen already
// shows, so every input is available to the wearer beside the verdict.

/// What a lane's recent training is doing, in the vocabulary Polar made familiar.
public enum TrainingStatus: String, Sendable, CaseIterable, Codable {
    /// Well below the wearer's usual, with no hard phase just before it.
    case detraining
    /// Well below usual straight after a productive or overreaching phase — a deload, not a decline.
    case recovering
    /// About the usual load; fitness is being held rather than built.
    case maintaining
    /// Load at or a little above usual, and — for strength — the lifts moving up.
    case productive
    /// Strength only: load at or above usual while the lifts are not improving.
    case unproductive
    /// Load well above usual (cardio), or well above usual with recovery signals down (strength).
    case overreaching
}

/// Where the ratio sits on Polar's scale.
public enum TrainingLoadBand: String, Sendable, CaseIterable {
    /// Below 0.8.
    case below
    /// 0.8 up to (not including) 1.0.
    case maintaining
    /// 1.0 up to and including 1.3.
    case productive
    /// Above 1.3.
    case above
}

/// How the body has been coping over the last few nights, from `ReadinessEngine`'s recovery signals.
public enum RecoveryState: String, Sendable {
    /// Signals within the wearer's normal range on most recent nights.
    case holding
    /// At least two of the recent nights flagged a recovery signal.
    case strained
    /// Too few nights with recovery data to say.
    case unknown
}

/// Which way the trained lifts are moving, judged from their own e1RM lines.
public enum StrengthResponse: String, Sendable {
    case rising
    /// Lifts were evaluated but do not agree on a direction. A statement about the evidence, not a
    /// plateau verdict — the same restraint `StrengthTrendLine.directionIsUnclear` documents.
    case unclear
    case falling
    /// Too few lifts with enough sessions in the window to judge.
    case unknown
}

/// One lift's six-week e1RM line, as the strength response read it.
public struct LiftTrend: Equatable, Sendable {
    public let templateId: String
    /// `.rising`, `.falling` or `.unclear` — never `.unknown`; lifts that cannot be judged are omitted.
    public let direction: StrengthResponse
    /// Theil–Sen slope of the session-best e1RM, kg per week.
    public let slopePerWeekKg: Double
    /// Estimable sessions inside the window.
    public let sessions: Int

    public init(templateId: String, direction: StrengthResponse, slopePerWeekKg: Double, sessions: Int) {
        self.templateId = templateId
        self.direction = direction
        self.slopePerWeekKg = slopePerWeekKg
        self.sessions = sessions
    }
}

/// The lift-by-lift evidence behind a `StrengthResponse`, so the screen can show its working.
public struct StrengthResponseReading: Equatable, Sendable {
    public let direction: StrengthResponse
    public let rising: Int
    public let falling: Int
    public let unclear: Int
    /// Every evaluated lift, the most sessions first — what the screen lists under "strength development".
    public let lifts: [LiftTrend]

    public init(direction: StrengthResponse, rising: Int, falling: Int, unclear: Int,
                lifts: [LiftTrend] = []) {
        self.direction = direction
        self.rising = rising
        self.falling = falling
        self.unclear = unclear
        self.lifts = lifts
    }

    /// Lifts that had enough sessions in the window to draw a line through.
    public var evaluated: Int { rising + falling + unclear }
}

/// The recovery evidence behind a `RecoveryState`.
public struct RecoveryReading: Equatable, Sendable {
    public let state: RecoveryState
    /// Nights, of those read, on which a recovery signal flagged.
    public let strainedNights: Int
    /// Nights in the window that carried any recovery signal at all.
    public let nightsRead: Int
    /// Signal keys ("hrv", "rhr", "respRate") flagging on the most recent night read.
    public let flaggingOnLatestNight: [String]
    /// Signal keys present at all on that night — so a missing reading shows as missing, not as normal.
    public let readOnLatestNight: [String]

    public init(state: RecoveryState, strainedNights: Int, nightsRead: Int, flaggingOnLatestNight: [String],
                readOnLatestNight: [String] = []) {
        self.state = state
        self.strainedNights = strainedNights
        self.nightsRead = nightsRead
        self.flaggingOnLatestNight = flaggingOnLatestNight
        self.readOnLatestNight = readOnLatestNight
    }
}

/// Which way cardiorespiratory fitness is moving — VO₂max up is `improving`.
public enum FitnessDirection: String, Sendable {
    case improving
    /// Evaluated, but the readings do not agree on a direction.
    case unclear
    case worsening
    /// Too few readings in the window to judge.
    case unknown
}

/// One VO₂max reading and where it came from.
public struct VO2maxReading: Equatable, Sendable {
    public let day: String
    public let value: Double
    /// The source or estimator behind the value ("apple-health", or the NOOP estimator id). A line is
    /// only ever drawn within one segment: switching estimator moves the number without any change in
    /// the person, and a trend across the switch would report the method change as fitness.
    public let segment: String

    public init(day: String, value: Double, segment: String) {
        self.day = day
        self.value = value
        self.segment = segment
    }
}

/// Which way VO₂max has moved over the window, and the readings behind it.
public struct VO2maxResponse: Equatable, Sendable {
    public let direction: FitnessDirection
    /// The readings the line was drawn through, oldest first — all from one segment.
    public let readings: [VO2maxReading]
    /// Theil–Sen slope, ml/kg/min per week; nil below four readings.
    public let slopePerWeek: Double?
    /// The change the line implies across its own span, ml/kg/min.
    public let changeOverSpan: Double?
    public let spanDays: Int
    /// True when older in-window readings came from another source or estimator and were left out.
    public let segmentBreak: Bool

    public init(direction: FitnessDirection, readings: [VO2maxReading], slopePerWeek: Double?,
                changeOverSpan: Double?, spanDays: Int, segmentBreak: Bool) {
        self.direction = direction
        self.readings = readings
        self.slopePerWeek = slopePerWeek
        self.changeOverSpan = changeOverSpan
        self.spanDays = spanDays
        self.segmentBreak = segmentBreak
    }

    public var latest: VO2maxReading? { readings.last }
}

/// The warning above the six states: overreaching that has lasted, with the lane's performance falling
/// and recovery strained. Not a diagnosis — see `TrainingStatusModel.sustainedOverreaching`.
public struct SustainedOverreaching: Equatable, Sendable {
    public enum Lane: String, Sendable { case strength, cardio }
    public let lanes: [Lane]
    /// Consecutive week-ends the longest-running flagged lane has been overreaching.
    public let weeks: Int

    public init(lanes: [Lane], weeks: Int) {
        self.lanes = lanes
        self.weeks = weeks
    }
}

/// One lane's verdict and what it rests on.
public struct LaneStatus: Equatable, Sendable {
    public let status: TrainingStatus
    /// Seven-day mean over baseline mean — the figure Polar calls Strain / Tolerance.
    public let ratio: Double
    public let band: TrainingLoadBand
    /// True when the ratio stood at or above 1.0 on at least half of the previous fourteen days.
    public let followsRecentHighPhase: Bool
    /// Consecutive days below 0.8, ending today; 0 unless the lane is in the below band.
    public let daysBelowUsual: Int
    /// False when the strength verdict had to fall back to load alone (too few evaluable lifts).
    public let usedStrengthResponse: Bool
    /// True when recovery signals decided the verdict (strength, above 1.3, with recovery data).
    public let usedRecovery: Bool

    public init(status: TrainingStatus, ratio: Double, band: TrainingLoadBand,
                followsRecentHighPhase: Bool, daysBelowUsual: Int = 0,
                usedStrengthResponse: Bool, usedRecovery: Bool) {
        self.status = status
        self.ratio = ratio
        self.band = band
        self.followsRecentHighPhase = followsRecentHighPhase
        self.daysBelowUsual = daysBelowUsual
        self.usedStrengthResponse = usedStrengthResponse
        self.usedRecovery = usedRecovery
    }
}

public enum TrainingStatusModel {

    // MARK: Polar's published thresholds

    /// Below this, Polar reports detraining or recovering.
    public static let detrainingBelow = 0.8
    /// From this (inclusive), Polar reports productive.
    public static let productiveFrom = 1.0
    /// Above this, Polar reports overreaching.
    public static let overreachingAbove = 1.3

    // MARK: NOOP's own choices, each named where it is shown

    /// How far back a productive or overreaching phase turns "detraining" into "recovering".
    public static let recentHighLookbackDays = 14
    /// Share of those days that must have stood at or above 1.0 for them to count as a PHASE. A single
    /// day at 1.0 is just an ordinary week — steady training sits exactly there — and would otherwise
    /// turn every break into "recovering". With half the fortnight required, a week off after regular
    /// training reads as recovering and a second week as detraining.
    public static let recentHighMinimumShare = 0.5
    /// The window the lifts' e1RM lines are drawn over. Six weeks is a typical training block: long
    /// enough for a strength change to exceed session-to-session scatter, short enough to describe the
    /// current block rather than last season.
    public static let responseWindowDays = 42
    /// Fewer evaluable lifts than this and the strength verdict falls back to load alone.
    public static let minimumLiftsForResponse = 2
    /// Recent nights read for the recovery state.
    public static let recoveryNights = 3
    /// Nights, of those read, that must flag before recovery counts as strained. One night is noise.
    public static let strainedNightsNeeded = 2
    /// Days below 0.8 before a strength lane whose lifts are not visibly falling is called detraining.
    /// From Bosquet et al. 2013 (meta-analysis of training cessation): the loss of maximal force becomes
    /// significant from the THIRD week of inactivity. Before that, strength is still being held, and
    /// "detraining" would describe a change the lifter's strength has not yet made.
    public static let strengthDetrainingAfterDays = 21
    /// How far back a run of below-usual days is counted — comfortably past the 21 days it decides on.
    static let belowRunLookbackDays = 60

    // MARK: - The scale

    public static func band(ratio: Double) -> TrainingLoadBand {
        if ratio < detrainingBelow { return .below }
        if ratio < productiveFrom { return .maintaining }
        if ratio <= overreachingAbove { return .productive }
        return .above
    }

    /// Whether the `recentHighLookbackDays` days before `day` were a productive or overreaching PHASE:
    /// the ratio stood at or above 1.0 on at least `recentHighMinimumShare` of them.
    ///
    /// Each earlier day's ratio is the same `TrainingLoad.trend` comparison, evaluated as of that day, so
    /// "recovering" is judged against what the screen would have shown then.
    public static func followsRecentHighPhase(dailyByDay: [String: Double], through day: String) -> Bool {
        var cursor = day
        var highDays = 0
        for _ in 0..<recentHighLookbackDays {
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
            if let trend = TrainingLoad.trend(dailyByDay: dailyByDay, through: cursor),
               trend.ratio >= productiveFrom {
                highDays += 1
            }
        }
        return Double(highDays) >= Double(recentHighLookbackDays) * recentHighMinimumShare
    }

    /// Consecutive days, ending on `day`, on which the ratio stood below 0.8 — how long the lane has been
    /// training well under its usual level. A day without a comparison ends the run.
    public static func daysBelowUsual(dailyByDay: [String: Double], through day: String) -> Int {
        var run = 0
        var cursor = day
        for _ in 0..<belowRunLookbackDays {
            guard let trend = TrainingLoad.trend(dailyByDay: dailyByDay, through: cursor),
                  trend.ratio < detrainingBelow else { break }
            run += 1
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return run
    }

    // MARK: - Cardio: Polar's Cardio Load Status

    /// Polar's four states from the ratio, with NOOP's recovering rule below 0.8.
    public static func cardioStatus(ratio: Double, followsRecentHighPhase: Bool) -> TrainingStatus {
        switch band(ratio: ratio) {
        case .below:       return followsRecentHighPhase ? .recovering : .detraining
        case .maintaining: return .maintaining
        case .productive:  return .productive
        case .above:       return .overreaching
        }
    }

    /// The cardio lane's status, or nil while `TrainingLoad.trend` withholds a comparison.
    public static func cardio(dailyByDay: [String: Double], through day: String) -> LaneStatus? {
        guard let trend = TrainingLoad.trend(dailyByDay: dailyByDay, through: day) else { return nil }
        let recentHigh = followsRecentHighPhase(dailyByDay: dailyByDay, through: day)
        let laneBand = band(ratio: trend.ratio)
        return LaneStatus(status: cardioStatus(ratio: trend.ratio, followsRecentHighPhase: recentHigh),
                          ratio: trend.ratio, band: laneBand,
                          followsRecentHighPhase: recentHigh,
                          daysBelowUsual: laneBand == .below
                            ? daysBelowUsual(dailyByDay: dailyByDay, through: day) : 0,
                          usedStrengthResponse: false, usedRecovery: false)
    }

    // MARK: - Strength: load, the lifts' response, and recovery

    /// The strength decision table.
    ///
    /// | band        | rising      | unclear        | falling      | unknown (fallback) |
    /// |-------------|-------------|----------------|--------------|--------------------|
    /// | below 0.8   | maintaining | maintaining†   | detraining   | maintaining†       |
    /// | 0.8–1.0     | productive  | maintaining    | detraining   | maintaining        |
    /// | 1.0–1.3     | productive  | maintaining    | unproductive | productive         |
    /// | above 1.3   | productive* | unproductive*  | unproductive*| overreaching       |
    ///
    /// Below 0.8 straight after a high phase is `recovering` whatever the lifts do. † becomes
    /// `detraining` once the lane has been below 0.8 for `strengthDetrainingAfterDays` (21) days — the
    /// point from which Bosquet et al. find maximal force measurably lower. Above 1.3 the starred cells
    /// apply only while recovery is holding; strained or unknown recovery makes it `overreaching`, which
    /// is also Polar's verdict for that band. Apart from the Bosquet rule, the "unknown" column is
    /// Polar's own mapping, used whenever too few lifts can be judged — the fallback never invents a
    /// response.
    ///
    /// "Unclear" at the usual load is `maintaining`, not `unproductive`: an advanced lifter gaining a
    /// fraction of a per cent a week is genuinely progressing below what six weeks of e1RM can resolve,
    /// and calling that unproductive would be a claim the data cannot make.
    public static func strengthStatus(ratio: Double, followsRecentHighPhase: Bool,
                                      response: StrengthResponse,
                                      recovery: RecoveryState,
                                      daysBelowUsual: Int = 0) -> TrainingStatus {
        switch band(ratio: ratio) {
        case .below:
            if followsRecentHighPhase { return .recovering }
            switch response {
            case .falling:            return .detraining
            case .rising:             return .maintaining
            case .unclear, .unknown:
                return daysBelowUsual >= strengthDetrainingAfterDays ? .detraining : .maintaining
            }
        case .maintaining:
            switch response {
            case .rising:             return .productive
            case .falling:            return .detraining
            case .unclear, .unknown:  return .maintaining
            }
        case .productive:
            switch response {
            case .rising, .unknown:   return .productive
            case .unclear:            return .maintaining
            case .falling:            return .unproductive
            }
        case .above:
            guard recovery == .holding else { return .overreaching }
            switch response {
            case .rising:             return .productive
            case .unclear, .falling:  return .unproductive
            case .unknown:            return .overreaching
            }
        }
    }

    /// The strength lane's status, or nil while `TrainingLoad.trend` withholds a comparison.
    public static func strength(dailyByDay: [String: Double], through day: String,
                                response: StrengthResponseReading,
                                recovery: RecoveryReading) -> LaneStatus? {
        guard let trend = TrainingLoad.trend(dailyByDay: dailyByDay, through: day) else { return nil }
        let recentHigh = followsRecentHighPhase(dailyByDay: dailyByDay, through: day)
        let laneBand = band(ratio: trend.ratio)
        let below = laneBand == .below ? daysBelowUsual(dailyByDay: dailyByDay, through: day) : 0
        let status = strengthStatus(ratio: trend.ratio, followsRecentHighPhase: recentHigh,
                                    response: response.direction, recovery: recovery.state,
                                    daysBelowUsual: below)
        return LaneStatus(status: status, ratio: trend.ratio, band: laneBand,
                          followsRecentHighPhase: recentHigh,
                          daysBelowUsual: below,
                          usedStrengthResponse: response.direction != .unknown,
                          usedRecovery: laneBand == .above && recovery.state != .unknown)
    }

    // MARK: - History

    /// One week-end's verdict per lane, for the history strip.
    public struct WeeklyStatus: Equatable, Sendable {
        public let day: String
        public let strength: TrainingStatus?
        public let cardio: TrainingStatus?
    }

    /// The status each lane would have shown at the end of each of the last `weeks` weeks, oldest first,
    /// the last entry being `day` itself.
    ///
    /// Every verdict is recomputed AS OF its own day — load, the lifts' six-week lines and the recovery
    /// nights — so the strip shows what the screen would have said then, not today's inputs painted
    /// backwards over old weeks.
    public static func weeklyHistory(weeks: Int, through day: String,
                                     strengthDaily: [String: Double], cardioDaily: [String: Double],
                                     workouts: [HevyWorkout], templates: [String: HevyExerciseTemplate],
                                     days: [DailyMetric], tzOffsetSeconds: Int = 0) -> [WeeklyStatus] {
        guard weeks > 0 else { return [] }
        return (0..<weeks).reversed().map { back in
            let asOf = WeeklyDigestEngine.addDays(day, -7 * back)
            let response = strengthResponse(workouts: workouts, templates: templates, through: asOf,
                                            tzOffsetSeconds: tzOffsetSeconds)
            let recoveryReading = recovery(days: days, through: asOf)
            return WeeklyStatus(
                day: asOf,
                strength: strength(dailyByDay: strengthDaily, through: asOf,
                                   response: response, recovery: recoveryReading)?.status,
                cardio: cardio(dailyByDay: cardioDaily, through: asOf)?.status)
        }
    }

    /// Which way the lifts trained in the last `responseWindowDays` are moving.
    ///
    /// Each lift gets the exercise card's own e1RM line (`StrengthProgress.e1rmTrend`, Theil–Sen over
    /// session bests) drawn through the sessions inside the window only. A lift rises when the middle
    /// half of its pairwise slopes is entirely above zero, falls when it is entirely below, and is
    /// unclear otherwise — so a direction is only claimed when the sessions agree on it, with no
    /// threshold added on top. Lifts with fewer than `StrengthProgress.minimumTrendPoints` estimable
    /// sessions in the window, and movements with no e1RM (planks, unweighted bodyweight work), are left
    /// out rather than counted as flat.
    ///
    /// The lifts are then read together: the block is rising when at least a third of the evaluated
    /// lifts rise and more rise than fall; falling by the same rule reversed; unclear otherwise.
    public static func strengthResponse(workouts: [HevyWorkout],
                                        templates: [String: HevyExerciseTemplate],
                                        through day: String,
                                        tzOffsetSeconds: Int = 0) -> StrengthResponseReading {
        let first = WeeklyDigestEngine.addDays(day, -(responseWindowDays - 1))
        let inWindow = workouts.filter {
            let workoutDay = AnalyticsEngine.dayString($0.startTs, offsetSec: tzOffsetSeconds)
            return workoutDay >= first && workoutDay <= day
        }
        let templateIds = Set(inWindow.flatMap { $0.exercises.compactMap(\.templateId) })

        var rising = 0, falling = 0, unclear = 0
        var lifts: [LiftTrend] = []
        for id in templateIds.sorted() {
            let points = StrengthSession.exerciseHistory(templateId: id, workouts: inWindow,
                                                         templates: templates,
                                                         tzOffsetSeconds: tzOffsetSeconds)
            guard let line = StrengthProgress.e1rmTrend(points) else { continue }
            let liftDirection: StrengthResponse
            if line.directionIsUnclear { unclear += 1; liftDirection = .unclear }
            else if line.slopePerWeek > 0 { rising += 1; liftDirection = .rising }
            else { falling += 1; liftDirection = .falling }
            lifts.append(LiftTrend(templateId: id, direction: liftDirection,
                                   slopePerWeekKg: line.slopePerWeek, sessions: line.pointCount))
        }
        // Most-trained lifts first, then by id so the order never depends on set iteration.
        lifts.sort { ($0.sessions, $1.templateId) > ($1.sessions, $0.templateId) }

        let evaluated = rising + falling + unclear
        let direction: StrengthResponse
        if evaluated < minimumLiftsForResponse {
            direction = .unknown
        } else {
            let quorum = max(1, Int((Double(evaluated) / 3).rounded(.up)))
            if rising >= quorum && rising > falling { direction = .rising }
            else if falling >= quorum && falling > rising { direction = .falling }
            else { direction = .unclear }
        }
        return StrengthResponseReading(direction: direction, rising: rising, falling: falling, unclear: unclear,
                                       lifts: lifts)
    }

    // MARK: - VO₂max response

    /// The window VO₂max is read over. Estimates arrive weekly, so eight weeks gives the line eight points
    /// — twice the minimum a direction may be claimed from.
    public static let vo2maxWindowDays = 56

    /// Which way VO₂max has moved over the last `vo2maxWindowDays` — cardio's answer to "is it working".
    ///
    /// Garmin calls a training load "productive" only while VO₂max rises; this is that marker, shown
    /// beside Polar's load status rather than changing it. The line is the same Theil–Sen estimator and
    /// agreement rule as a lift (a direction only when the middle half of the pairwise slopes excludes
    /// zero; at least `StrengthProgress.minimumTrendPoints` readings), drawn through the most recent
    /// SEGMENT only: readings from another source or estimator earlier in the window are left out and
    /// `segmentBreak` says so, because a method switch moves the number without any change in fitness.
    public static func vo2maxResponse(readings: [VO2maxReading], through day: String) -> VO2maxResponse {
        let first = WeeklyDigestEngine.addDays(day, -(vo2maxWindowDays - 1))
        let inWindow = readings
            .filter { $0.day >= first && $0.day <= day && $0.value > 0 }
            .sorted { $0.day < $1.day }
        guard let segment = inWindow.last?.segment else {
            return VO2maxResponse(direction: .unknown, readings: [], slopePerWeek: nil,
                                  changeOverSpan: nil, spanDays: 0, segmentBreak: false)
        }
        var kept: [VO2maxReading] = []
        for reading in inWindow.reversed() {
            guard reading.segment == segment else { break }
            kept.insert(reading, at: 0)
        }
        let points = kept.map { reading in
            ExercisePerformancePoint(day: reading.day,
                                     startTs: StrengthSession.daysBetween("1970-01-01", and: reading.day) * 86_400 + 43_200,
                                     workoutId: "", bestE1RMKg: reading.value, heaviestSetKg: nil,
                                     workingSetCount: 0, totalReps: 0, volumeLoadKg: 0, meanRpe: nil, rpeSetCount: 0)
        }
        let line = StrengthProgress.e1rmTrend(points)
        let direction: FitnessDirection
        if let line {
            direction = line.directionIsUnclear ? .unclear : (line.slopePerWeek > 0 ? .improving : .worsening)
        } else {
            direction = .unknown
        }
        return VO2maxResponse(direction: direction, readings: kept, slopePerWeek: line?.slopePerWeek,
                              changeOverSpan: line?.changeOverSpan, spanDays: line?.spanDays ?? 0,
                              segmentBreak: kept.count < inWindow.count)
    }

    // MARK: - Sustained overreaching

    /// Consecutive week-ends a lane must have been overreaching before the warning can show.
    public static let sustainedOverreachingWeeks = 3

    /// Overreaching that has lasted, with that lane's performance falling and recovery strained.
    ///
    /// The ECSS/ACSM consensus (Meeusen et al. 2013) separates functional overreaching — a planned hard
    /// block, recovered from in days and followed by better performance, which is what the ordinary
    /// "overreaching" status means — from NON-functional overreaching: a performance decrement that
    /// takes weeks to months to recover from. This warning is the pattern of the second: overreaching at
    /// `sustainedOverreachingWeeks` week-ends in a row, the same lane's performance falling (lifts for
    /// strength, VO₂max for cardio), and recovery strained now. All three are
    /// required; a missing performance reading never raises it.
    ///
    /// It is NOT a diagnosis of the overtraining syndrome. The same consensus says that can only be
    /// made clinically — over months, by excluding infection, energy deficit, iron deficiency and the
    /// like — and that no single marker qualifies. The screen says exactly that and points to rest and,
    /// if it persists, to a doctor.
    public static func sustainedOverreaching(history: [WeeklyStatus],
                                             strengthResponse: StrengthResponseReading,
                                             cardioDirection: FitnessDirection,
                                             recovery: RecoveryReading) -> SustainedOverreaching? {
        guard recovery.state == .strained, history.count >= sustainedOverreachingWeeks else { return nil }

        func run(_ status: (WeeklyStatus) -> TrainingStatus?) -> Int {
            var count = 0
            for week in history.reversed() {
                guard status(week) == .overreaching else { break }
                count += 1
            }
            return count
        }

        var lanes: [SustainedOverreaching.Lane] = []
        var weeks = 0
        let strengthRun = run { $0.strength }
        if strengthRun >= sustainedOverreachingWeeks, strengthResponse.direction == .falling {
            lanes.append(.strength)
            weeks = max(weeks, strengthRun)
        }
        let cardioRun = run { $0.cardio }
        if cardioRun >= sustainedOverreachingWeeks, cardioDirection == .worsening {
            lanes.append(.cardio)
            weeks = max(weeks, cardioRun)
        }
        return lanes.isEmpty ? nil : SustainedOverreaching(lanes: lanes, weeks: weeks)
    }

    // MARK: - Recovery

    /// How recovery has held up over the `recoveryNights` nights ending on `day`.
    ///
    /// Each night is `ReadinessEngine.evaluate` as of that day, reading only the three RECOVERY signals —
    /// HRV, resting HR, respiratory rate. Its training-load signal is deliberately ignored: it is itself
    /// a heart-rate load ratio, and letting it vote here would count the cardio lane twice. A night is
    /// strained when a recovery signal is `.bad` or two are `.watch`; recovery is strained when
    /// `strainedNightsNeeded` of the nights read are. Fewer than two nights with any recovery signal is
    /// `unknown`, because one night cannot tell a trend from a bad night's sleep.
    public static func recovery(days: [DailyMetric], through day: String) -> RecoveryReading {
        let recoveryKeys: Set<String> = ["hrv", "rhr", "respRate"]
        var strainedNights = 0
        var nightsRead = 0
        var latestFlagging: [String]?
        var latestRead: [String] = []
        var cursor = day
        for _ in 0..<recoveryNights {
            let readiness = ReadinessEngine.evaluate(days: days, today: cursor)
            let signals = readiness.signals.filter { recoveryKeys.contains($0.key) }
            if !signals.isEmpty {
                nightsRead += 1
                let bad = signals.filter { $0.flag == .bad }.count
                let watch = signals.filter { $0.flag == .watch }.count
                if bad >= 1 || watch >= 2 { strainedNights += 1 }
                if latestFlagging == nil {
                    latestFlagging = signals.filter { $0.flag == .bad || $0.flag == .watch }.map(\.key)
                    latestRead = signals.map(\.key)
                }
            }
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        let state: RecoveryState
        if nightsRead < 2 { state = .unknown }
        else if strainedNights >= strainedNightsNeeded { state = .strained }
        else { state = .holding }
        return RecoveryReading(state: state, strainedNights: strainedNights, nightsRead: nightsRead,
                               flaggingOnLatestNight: latestFlagging ?? [], readOnLatestNight: latestRead)
    }
}
