import Foundation
import WhoopStore

// MARK: - Is this training doing anything? A status per lane
//
// `TrainingLoad` answers "how much, compared with your usual". This file answers the question people
// actually ask of that number: is it too much, too little, or about right. It does so in the terms the
// two lanes can honestly support, and the two lanes are NOT treated alike.
//
// CARDIO uses a seven-day mean of daily load against the PRECEDING 28 days. The windows are disjoint,
// avoiding the mathematical coupling that appears when the acute week is also part of its own baseline.
// The familiar 0.8 / 1.0 / 1.3 bands remain a monitoring convention for readable states, not measured
// safety limits or a validated injury predictor. The cardio status is computed from cardio load ONLY.
//
// STRENGTH is where nobody has published a validated status. The established load models are all
// cardiovascular: heart-rate EPOC and power-based muscle load need running or cycling, WHOOP folds an
// unvalidated wrist-motion estimate into Strain, and Apple asks for a manual effort rating. The 2025
// ACWR meta-analysis (22 studies) contains no resistance-training study, and even for the sports it
// covers it does not call 0.8–1.3 reliably safe. So the ratio alone is not allowed to call a strength
// block "productive". The status also asks whether anything improved — the established idea that
// "productive" needs load AND a rising VO2max. For lifting, the improvement that can be measured is the
// estimated one-rep max of the lifts being trained: `StrengthProgress.e1rmTrend`, the same robust line
// the exercise card draws, restricted to the last six weeks. And above 1.3 it asks the body, through the
// recovery signals `ReadinessEngine` already reads (HRV, resting HR, respiratory rate).
//
// Two rules here are NOOP's own and are named as such wherever they are shown:
//   • "Recovering" rather than "detraining" when the ratio has dropped below 0.8 within two weeks of a
//     productive or overreaching phase. The published scales distinguish the two but not how.
//   • The strength decision table below, and the aggregation of several lifts into one direction.
//
// Nothing here is stored or feeds a score. It is a read-time label over figures the screen already
// shows, so every input is available to the wearer beside the verdict.

/// What a lane's recent training is doing, in the vocabulary load monitoring has made familiar.
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

/// Where the ratio sits on the load scale.
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

/// Adaptation is reported separately from load: it requires a measured performance response.
public enum TrainingAdaptationState: String, Equatable, Sendable, Codable {
    case improving
    case stable
    case declining
    case unclear
    case notEnoughData
}

public enum TrainingAdaptationEvidence: String, Equatable, Sendable, Codable {
    case estimatedOneRepMax
    case vo2max
}

public struct TrainingAdaptationReading: Equatable, Sendable {
    public let state: TrainingAdaptationState
    public let evidence: TrainingAdaptationEvidence
    public let observations: Int

    public init(state: TrainingAdaptationState, evidence: TrainingAdaptationEvidence,
                observations: Int) {
        self.state = state
        self.evidence = evidence
        self.observations = observations
    }
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
    /// Seven-day mean over the preceding baseline mean — an uncoupled load ratio.
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

    // MARK: The conventional published thresholds

    /// Below this, the scale reports detraining or recovering.
    public static let detrainingBelow = 0.8
    /// From this (inclusive), the scale reports productive.
    public static let productiveFrom = 1.0
    /// Above this, the scale reports overreaching.
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
    /// Recovery context needs most of a week, not one or two noisy nights.
    public static let minimumRecoveryNights = 4
    /// Recent nights read for the recovery state.
    ///
    /// A WEEK, so the reading describes a period rather than a weekend. Over three nights one poor night
    /// beside one mediocre one was already "your recovery is strained" — and this state is not decorative:
    /// it gates the strength lane's top band, where it decides between `productive` and `overreaching`.
    /// Seven nights is also the window every other acute figure on the screen uses.
    public static let recoveryNights = 7
    /// Share of the nights ACTUALLY READ that must flag before recovery counts as strained.
    public static let strainedNightShare = 0.5
    /// Nights that must flag however the share works out. One night is noise.
    public static let strainedNightsFloor = 2
    /// Days below 0.8 before a CARDIO lane is called detraining rather than simply quiet.
    ///
    /// Short-term detraining research (Mujika & Padilla 2000) finds aerobic capacity largely held through
    /// roughly the first fortnight of stopped or reduced training, and measurably lower after it. Before
    /// that, a quiet week is a quiet week, and "detraining" would name a loss the athlete has not had.
    /// The strength lane waits longer (`strengthDetrainingAfterDays`): maximal force decays more slowly
    /// than aerobic capacity, and the two lanes should not borrow each other's timing.
    public static let cardioDetrainingAfterDays = 14
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
    public static func followsRecentHighPhase(dailyByDay: [String: Double], through day: String,
                                              unknownDays: Set<String> = []) -> Bool {
        var cursor = day
        var highDays = 0
        for _ in 0..<recentHighLookbackDays {
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
            if let trend = TrainingLoad.trend(dailyByDay: dailyByDay, through: cursor,
                                              unknownDays: unknownDays),
               trend.ratio >= productiveFrom {
                highDays += 1
            }
        }
        return Double(highDays) >= Double(recentHighLookbackDays) * recentHighMinimumShare
    }

    /// Consecutive days, ending on `day`, on which the ratio stood below 0.8 — how long the lane has been
    /// training well under its usual level. A day without a comparison ends the run.
    public static func daysBelowUsual(dailyByDay: [String: Double], through day: String,
                                      unknownDays: Set<String> = []) -> Int {
        var run = 0
        var cursor = day
        for _ in 0..<belowRunLookbackDays {
            guard let trend = TrainingLoad.trend(dailyByDay: dailyByDay, through: cursor,
                                                 unknownDays: unknownDays),
                  trend.ratio < detrainingBelow else { break }
            run += 1
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        return run
    }

    // MARK: - Cardio: the four load states

    /// The four states from the ratio, with NOOP's recovering rule below 0.8.
    ///
    /// Below 0.8 is `detraining` only once the lane has been there for `cardioDetrainingAfterDays`; until
    /// then it is `maintaining`. A single quiet week is the most ordinary thing in a training year — a
    /// deload, a work trip, a cold — and reporting it as a loss of fitness on day one told the athlete
    /// something untrue about their body while the number only described their calendar.
    public static func cardioStatus(ratio: Double, followsRecentHighPhase: Bool,
                                    daysBelowUsual: Int = 0) -> TrainingStatus {
        switch band(ratio: ratio) {
        case .below:
            if followsRecentHighPhase { return .recovering }
            return daysBelowUsual >= cardioDetrainingAfterDays ? .detraining : .maintaining
        case .maintaining: return .maintaining
        case .productive:  return .productive
        case .above:       return .overreaching
        }
    }

    /// The cardio lane's status, or nil while `TrainingLoad.trend` withholds a comparison.
    ///
    /// `unknownDays` are days whose cardio the data cannot price at all — not rest days. They drop out of
    /// both comparison windows here and in every helper below, so the phase test and the below-usual run
    /// are read from the same series as the ratio itself.
    public static func cardio(dailyByDay: [String: Double], through day: String,
                              unknownDays: Set<String> = []) -> LaneStatus? {
        guard let trend = TrainingLoad.trend(dailyByDay: dailyByDay, through: day,
                                             unknownDays: unknownDays) else { return nil }
        let recentHigh = followsRecentHighPhase(dailyByDay: dailyByDay, through: day,
                                                unknownDays: unknownDays)
        let laneBand = band(ratio: trend.ratio)
        let belowRun = laneBand == .below
            ? daysBelowUsual(dailyByDay: dailyByDay, through: day, unknownDays: unknownDays) : 0
        return LaneStatus(status: cardioStatus(ratio: trend.ratio, followsRecentHighPhase: recentHigh,
                                               daysBelowUsual: belowRun),
                          ratio: trend.ratio, band: laneBand,
                          followsRecentHighPhase: recentHigh,
                          daysBelowUsual: belowRun,
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
    /// is also the conventional verdict for that band. Apart from the Bosquet rule, the "unknown" column
    /// is the conventional load-only mapping, used whenever too few lifts can be judged — the fallback
    /// never invents a response.
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

    // MARK: - One statement for both lanes

    public enum TrainingStatementLane: String, Sendable, CaseIterable { case strength, cardio }
    public enum TrainingStatementSeverity: String, Sendable { case mild, sharp }

    /// What the two lanes say TOGETHER — the page's single statement.
    ///
    /// It is a mapping, not a fourth score: every case names the lanes it speaks for, and no case
    /// merges the two verdicts into a third one.
    public enum TrainingStatement: Equatable, Sendable {
        case noHistory
        /// Only one lane has a comparison yet; the other is not yet measurable.
        case laneOnly(TrainingStatementLane, TrainingStatus)
        case aligned(TrainingStatus)
        /// One lane below its usual while the other merely holds — not yet a split, but not "both low".
        case oneBehind(TrainingStatementLane)
        /// The lanes point in opposite directions: one below usual, the other building or overreaching.
        case split(low: TrainingStatementLane, high: TrainingStatementLane,
                   severity: TrainingStatementSeverity)
        case excessive(TrainingStatementLane, recoveryStrained: Bool)
        case bothExcessive(recoveryStrained: Bool)
        case spinning(cardioAlsoHigh: Bool)
        case strainedRecovery
    }

    /// Which way a lane is pointing. Derived from the verdict rather than from a second threshold, so a
    /// split is decided by the rules that already priced each lane — including strength's own
    /// exceptions (the lifts' response, recovery above 1.3, the 21-day detraining rule).
    private enum Tendency { case behind, holding, building, spinning, excessive }

    private static func tendency(_ status: TrainingStatus) -> Tendency {
        switch status {
        case .detraining, .recovering: return .behind
        case .maintaining:             return .holding
        case .productive:              return .building
        case .unproductive:            return .spinning
        case .overreaching:            return .excessive
        }
    }

    /// The statement for one pair of verdicts.
    ///
    /// The old read-time ladder stopped at its first hit and therefore named ONE lane: a wearer whose
    /// lifting was falling away while their cardio ran well above usual was told only about the cardio.
    /// This resolves the pair instead, so a lane that is losing ground is never silently dropped from
    /// the sentence.
    ///
    /// Strained recovery is applied AFTER the pair is resolved, and only where it changes the advice:
    /// it sharpens an overreaching statement and displaces a quiet one, but it never overrides a split
    /// or a lane that is falling behind — the recovery card sits directly beneath either way.
    public static func statement(strength: TrainingStatus?, cardio: TrainingStatus?,
                                 recovery: RecoveryState) -> TrainingStatement {
        let strained = recovery == .strained
        switch (strength, cardio) {
        case (nil, nil):                     return .noHistory
        case let (value?, nil):              return .laneOnly(.strength, value)
        case let (nil, value?):              return .laneOnly(.cardio, value)
        case let (strengthStatus?, cardioStatus?):
            let lifting = tendency(strengthStatus)
            let running = tendency(cardioStatus)
            switch (lifting, running) {
            case (.spinning, .excessive):    return .spinning(cardioAlsoHigh: true)
            case (.spinning, _):             return .spinning(cardioAlsoHigh: false)
            case (.excessive, .excessive):   return .bothExcessive(recoveryStrained: strained)
            case (.excessive, .behind):
                return .split(low: .cardio, high: .strength, severity: .sharp)
            case (.behind, .excessive):
                return .split(low: .strength, high: .cardio, severity: .sharp)
            case (.excessive, _):            return .excessive(.strength, recoveryStrained: strained)
            case (_, .excessive):            return .excessive(.cardio, recoveryStrained: strained)
            case (.behind, .building):
                return .split(low: .strength, high: .cardio, severity: .mild)
            case (.building, .behind):
                return .split(low: .cardio, high: .strength, severity: .mild)
            case (.behind, .behind):
                // The graver of the two claims wins: a deload beside a genuine decline is a decline.
                return .aligned(strengthStatus == .detraining || cardioStatus == .detraining
                                ? .detraining : .recovering)
            case (.behind, .holding):        return .oneBehind(.strength)
            case (.holding, .behind):        return .oneBehind(.cardio)
            // `cardioStatus` never returns `unproductive`, so these two pairs cannot occur today. They
            // are spelled out rather than swept into a `default`, which would also swallow a genuine
            // gap the day the matrix grows: load without return is still load at or above usual, so
            // cardio in that state is treated exactly like a building cardio lane.
            case (.behind, .spinning):
                return .split(low: .strength, high: .cardio, severity: .mild)
            case (.holding, .spinning):
                return strained ? .strainedRecovery : .aligned(.productive)
            case (.building, _), (_, .building):
                return strained ? .strainedRecovery : .aligned(.productive)
            case (.holding, .holding):
                return strained ? .strainedRecovery : .aligned(.maintaining)
            }
        }
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
                                     cardioUnknownDays: Set<String> = [],
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
                cardio: cardio(dailyByDay: cardioDaily, through: asOf,
                               unknownDays: cardioUnknownDays)?.status)
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

    /// How much VO₂max must have moved across the window before a direction is claimed, in ml/kg/min.
    ///
    /// An estimated VO₂max is not a measured one: it is inferred from heart rate and pace, and its
    /// typical error is around a point — comfortably larger than the drift a Theil–Sen line can call
    /// consistent. Without a floor, eight weeks of readings wobbling by half a point in one direction
    /// read as "your fitness is improving", which is a claim about the estimator rather than the
    /// athlete. Below this the direction is `unclear`: the line agreed, the change was too small to mean
    /// anything.
    public static let vo2maxMinimumChange = 1.5

    public static func strengthAdaptation(_ response: StrengthResponseReading) -> TrainingAdaptationReading {
        let state: TrainingAdaptationState
        switch response.direction {
        case .rising: state = .improving
        case .falling: state = .declining
        case .unclear: state = .unclear
        case .unknown: state = .notEnoughData
        }
        return TrainingAdaptationReading(state: state, evidence: .estimatedOneRepMax,
                                         observations: response.evaluated)
    }

    public static func cardiovascularAdaptation(_ response: VO2maxResponse) -> TrainingAdaptationReading {
        let state: TrainingAdaptationState
        switch response.direction {
        case .improving: state = .improving
        case .worsening: state = .declining
        case .unclear: state = .unclear
        case .unknown: state = .notEnoughData
        }
        return TrainingAdaptationReading(state: state, evidence: .vo2max,
                                         observations: response.readings.count)
    }

    /// Which way VO₂max has moved over the last `vo2maxWindowDays` — cardio's answer to "is it working".
    ///
    /// The established status models call a training load "productive" only while VO₂max rises; this is
    /// that marker, shown beside the load status rather than changing it. The line is the same estimator
    /// and
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
            if line.directionIsUnclear || abs(line.changeOverSpan) < vo2maxMinimumChange {
                direction = .unclear
            } else {
                direction = line.slopePerWeek > 0 ? .improving : .worsening
            }
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

    /// How many of the nights actually read must flag before recovery counts as strained.
    ///
    /// Proportional rather than fixed, because the window is a week: two flagged nights out of seven is
    /// an ordinary week with a bad Tuesday, while two out of three was most of what was read. The floor
    /// keeps a single night from ever deciding it, however few nights carried a signal.
    public static func strainedNightsNeeded(ofNightsRead nightsRead: Int) -> Int {
        max(strainedNightsFloor, Int((Double(nightsRead) * strainedNightShare).rounded(.up)))
    }

    /// How recovery has held up over the `recoveryNights` nights ending on `day`.
    ///
    /// Each night is `ReadinessEngine.evaluate` as of that day, reading only the three RECOVERY signals —
    /// HRV, resting HR, respiratory rate. Its training-load signal is deliberately ignored: it is itself
    /// a heart-rate load ratio, and letting it vote here would count the cardio lane twice. A night is
    /// strained when a recovery signal is `.bad` or two are `.watch`; recovery is strained when
    /// `strainedNightsNeeded(ofNightsRead:)` of the nights read are. Fewer than four nights with any
    /// recovery signal is `unknown`, because a few noisy nights cannot establish a week-level pattern.
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
        if nightsRead < minimumRecoveryNights { state = .unknown }
        else if strainedNights >= strainedNightsNeeded(ofNightsRead: nightsRead) { state = .strained }
        else { state = .holding }
        return RecoveryReading(state: state, strainedNights: strainedNights, nightsRead: nightsRead,
                               flaggingOnLatestNight: latestFlagging ?? [], readOnLatestNight: latestRead)
    }
}
