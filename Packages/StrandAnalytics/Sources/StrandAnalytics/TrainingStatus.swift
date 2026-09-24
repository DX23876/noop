import Foundation
import WhoopStore

// MARK: - Is this training doing anything? A verdict per lane
//
// `TrainingLoad` answers "how much, compared with your usual", and `LaneEngine` turns that into the one
// band every surface shows (below / usual / above / well above). This file answers the question people
// actually ask of that band — is it working, holding, or too much — and it only answers it where the
// data can: a JUDGEMENT needs performance evidence, a band alone is a description of the load.
//
// The evidence is the lane's own measured performance: the e1RM of the lifts being trained for strength
// (`StrengthProgress.e1rmTrend`, restricted to the last six weeks), and for cardio a measured VO₂max or
// the lane's heart-rate efficiency (supplied by the caller). The established idea is Garmin's —
// "productive" needs load AND an improving marker — applied with the marker each lane actually has. No
// wearable publishes a validated strength status, and the 2025 ACWR meta-analysis (22 studies) contains
// no resistance-training study and does not call any ratio band reliably safe, so a band alone may never
// call a block "productive". Well above usual also asks the body, through the recovery signals
// `ReadinessEngine` already reads (HRV, resting HR, respiratory rate).
//
// The verdict table itself is `LaneEngine.verdict`. What lives here is everything it reads: the lifts'
// response, the VO₂max line, recovery, and the two things built from verdicts — the page's single
// statement and the lasting-overload warning. The rules that are NOOP's own are named where shown:
//   • "Recovering" rather than "detraining" when a lane drops below usual after a high phase.
//   • The verdict table, and the aggregation of several lifts into one direction.
//
// Nothing here is stored or feeds a score. It is a read-time label over figures the screen already
// shows, so every input is available to the wearer beside the verdict.

/// What a lane's recent training is doing, in the vocabulary load monitoring has made familiar. Only
/// ever the judgement of `LaneEngine.verdict`, which needs performance evidence for anything but the
/// decline cases.
public enum TrainingStatus: String, Sendable, CaseIterable, Codable {
    /// Below usual for longer than the lane's detraining wait, or with performance falling.
    case detraining
    /// Below usual straight after a high phase — a deload, not a decline.
    case recovering
    /// Fitness is being held: performance unclear at the usual or a higher load, or rising below it.
    case maintaining
    /// Load at, above or well above usual with performance rising (and, well above, recovery holding).
    case productive
    /// Load at or above usual while performance is falling — work without return.
    case unproductive
    /// Well above usual with recovery not holding, or with performance falling.
    case overreaching
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

/// The warning above the verdicts: well-above-usual load that has lasted, with the lane's performance
/// falling and recovery strained. Not a diagnosis — see `TrainingStatusModel.sustainedOverreaching`.
public struct SustainedOverreaching: Equatable, Sendable {
    public enum Lane: String, Sendable { case strength, cardio }
    public let lanes: [Lane]
    /// Consecutive week-ends the longest-running flagged lane has been well above usual.
    public let weeks: Int

    public init(lanes: [Lane], weeks: Int) {
        self.lanes = lanes
        self.weeks = weeks
    }
}

public enum TrainingStatusModel {

    // MARK: NOOP's own choices, each named where it is shown

    /// The window the lifts' e1RM lines are drawn over. Six weeks is a typical training block: long
    /// enough for a strength change to exceed session-to-session scatter, short enough to describe the
    /// current block rather than last season.
    public static let responseWindowDays = 42
    /// Fewer evaluable lifts than this and the strength lane has no evidence: its verdict only describes
    /// the load.
    public static let minimumLiftsForResponse = 2
    /// Recovery context needs most of a week, not one or two noisy nights.
    public static let minimumRecoveryNights = 4
    /// Recent nights read for the recovery state.
    ///
    /// A WEEK, so the reading describes a period rather than a weekend. Over three nights one poor night
    /// beside one mediocre one was already "your recovery is strained" — and this state is not decorative:
    /// it gates the well-above band, where it decides between `productive` and `overreaching`.
    /// Seven nights is also the window every other acute figure on the screen uses.
    public static let recoveryNights = 7
    /// Share of the nights ACTUALLY READ that must flag before recovery counts as strained.
    public static let strainedNightShare = 0.5
    /// Nights that must flag however the share works out. One night is noise.
    public static let strainedNightsFloor = 2
    /// Days below usual before a CARDIO lane is called detraining rather than simply quiet.
    ///
    /// Short-term detraining research (Mujika & Padilla 2000) finds aerobic capacity largely held through
    /// roughly the first fortnight of stopped or reduced training, and measurably lower after it. Before
    /// that, a quiet week is a quiet week, and "detraining" would name a loss the athlete has not had.
    /// The strength lane waits longer (`strengthDetrainingAfterDays`): maximal force decays more slowly
    /// than aerobic capacity, and the two lanes should not borrow each other's timing.
    public static let cardioDetrainingAfterDays = 14
    /// Days below usual before a strength lane whose lifts are not visibly falling is called detraining.
    /// From Bosquet et al. 2013 (meta-analysis of training cessation): the loss of maximal force becomes
    /// significant from the THIRD week of inactivity. Before that, strength is still being held, and
    /// "detraining" would describe a change the lifter's strength has not yet made.
    public static let strengthDetrainingAfterDays = 21

    // MARK: - One statement for both lanes

    public enum TrainingStatementLane: String, Sendable, CaseIterable { case strength, cardio }
    public enum TrainingStatementSeverity: String, Sendable { case mild, sharp }

    /// What the two lanes say TOGETHER — the page's single statement.
    ///
    /// It is a mapping, not a fourth score: every case names the lanes it speaks for, and no case
    /// merges the two verdicts into a third one.
    public enum TrainingStatement: Equatable, Sendable {
        case noHistory
        /// Only one lane has a band yet; the other is not yet measurable.
        case laneOnly(TrainingStatementLane, LaneVerdict)
        case aligned(LaneVerdict)
        /// One lane below its usual while the other merely holds — not yet a split, but not "both low".
        case oneBehind(TrainingStatementLane)
        /// The lanes point in opposite directions: one below usual, the other at or above it and moving.
        case split(low: TrainingStatementLane, high: TrainingStatementLane,
                   severity: TrainingStatementSeverity)
        case excessive(TrainingStatementLane, recoveryStrained: Bool)
        case bothExcessive(recoveryStrained: Bool)
        /// One lane is trained at or above usual while its performance falls.
        case spinning(TrainingStatementLane, otherAlsoHigh: Bool)
        case bothSpinning
        case strainedRecovery
    }

    /// Which way a lane is pointing, derived from its verdict rather than from a second threshold.
    private enum Tendency { case behind, holding, building, spinning, excessive }

    private static func tendency(_ verdict: LaneVerdict) -> Tendency {
        switch verdict {
        case .status(.detraining), .status(.recovering), .loadOnly(.below): return .behind
        case .status(.maintaining), .loadOnly(.usual):                      return .holding
        case .status(.productive), .loadOnly(.higher):                      return .building
        case .status(.unproductive):                                        return .spinning
        case .status(.overreaching), .loadOnly(.muchHigher):                return .excessive
        }
    }

    /// The statement for one pair of verdicts.
    ///
    /// A lane that is losing ground is never silently dropped: whenever one lane is behind and the other
    /// is building, spinning or excessive, the answer is a `split` naming both. The pair is resolved
    /// symmetrically — cardio can be unproductive too, now that its evidence is a performance marker — so
    /// swapping the lanes swaps them in the answer.
    ///
    /// Strained recovery is applied AFTER the pair is resolved, and only where it changes the advice:
    /// it sharpens an overreaching statement and displaces a quiet one, but it never overrides a split
    /// or a lane that is falling behind — the recovery card sits directly beneath either way.
    public static func statement(strength: LaneVerdict?, cardio: LaneVerdict?,
                                 recovery: RecoveryState) -> TrainingStatement {
        let strained = recovery == .strained
        switch (strength, cardio) {
        case (nil, nil):                     return .noHistory
        case let (value?, nil):              return .laneOnly(.strength, value)
        case let (nil, value?):              return .laneOnly(.cardio, value)
        case let (strengthVerdict?, cardioVerdict?):
            let lifting = tendency(strengthVerdict)
            let running = tendency(cardioVerdict)
            switch (lifting, running) {
            case (.excessive, .excessive):   return .bothExcessive(recoveryStrained: strained)
            case (.behind, .excessive):      return .split(low: .strength, high: .cardio, severity: .sharp)
            case (.excessive, .behind):      return .split(low: .cardio, high: .strength, severity: .sharp)
            case (.behind, .building), (.behind, .spinning):
                return .split(low: .strength, high: .cardio, severity: .mild)
            case (.building, .behind), (.spinning, .behind):
                return .split(low: .cardio, high: .strength, severity: .mild)
            case (.spinning, .spinning):     return .bothSpinning
            case (.spinning, let other):     return .spinning(.strength, otherAlsoHigh: other == .excessive)
            case (let other, .spinning):     return .spinning(.cardio, otherAlsoHigh: other == .excessive)
            case (.excessive, _):            return .excessive(.strength, recoveryStrained: strained)
            case (_, .excessive):            return .excessive(.cardio, recoveryStrained: strained)
            case (.behind, .behind):
                // The graver of the two claims wins: a deload beside a genuine decline is a decline.
                let pair = [strengthVerdict, cardioVerdict]
                if pair.contains(.status(.detraining)) { return .aligned(.status(.detraining)) }
                if pair.contains(.status(.recovering)) { return .aligned(.status(.recovering)) }
                return .aligned(.loadOnly(.below))
            case (.behind, .holding):        return .oneBehind(.strength)
            case (.holding, .behind):        return .oneBehind(.cardio)
            case (.building, _), (_, .building):
                // Productive only when a building lane has the evidence for it; more load alone is
                // described, never praised.
                let proven = strengthVerdict == .status(.productive) || cardioVerdict == .status(.productive)
                return strained ? .strainedRecovery : .aligned(proven ? .status(.productive) : .loadOnly(.higher))
            case (.holding, .holding):
                let judged = strengthVerdict == .status(.maintaining) || cardioVerdict == .status(.maintaining)
                return strained ? .strainedRecovery : .aligned(judged ? .status(.maintaining) : .loadOnly(.usual))
            }
        }
    }

    // MARK: - History

    /// One week-end's band per lane, for the history strip.
    public struct WeeklyLoadBands: Equatable, Sendable {
        public let day: String
        public let strength: RelativeLoadBand?
        public let cardio: RelativeLoadBand?

        public init(day: String, strength: RelativeLoadBand?, cardio: RelativeLoadBand?) {
            self.day = day
            self.strength = strength
            self.cardio = cardio
        }
    }

    /// The week-ends of the last `weeks` weeks, oldest first, the last entry being `day` itself.
    public static func weekEnds(weeks: Int, through day: String) -> [String] {
        guard weeks > 0 else { return [] }
        return (0..<weeks).reversed().map { WeeklyDigestEngine.addDays(day, -7 * $0) }
    }

    /// The band each lane showed at each week-end, from readings taken AS OF that day — the strip shows
    /// what the screen said then, not today's inputs painted backwards over old weeks.
    public static func weeklyBands(strength: [LaneReading], cardio: [LaneReading]) -> [WeeklyLoadBands] {
        let days = strength.isEmpty ? cardio.map(\.day) : strength.map(\.day)
        return days.enumerated().map { index, day in
            WeeklyLoadBands(day: day,
                            strength: strength.indices.contains(index) ? strength[index].band : nil,
                            cardio: cardio.indices.contains(index) ? cardio[index].band : nil)
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

    /// Consecutive week-ends a lane must have been well above usual before the warning can show.
    public static let sustainedOverreachingWeeks = 3

    /// Overload that has lasted, with that lane's performance falling and recovery strained.
    ///
    /// The ECSS/ACSM consensus (Meeusen et al. 2013) separates functional overreaching — a planned hard
    /// block, recovered from in days and followed by better performance — from NON-functional
    /// overreaching: a performance decrement that takes weeks to months to recover from. This warning is
    /// the pattern of the second: well above usual at `sustainedOverreachingWeeks` week-ends in a row,
    /// the same lane's performance falling, and recovery strained now. All three are required; missing
    /// performance evidence never raises it.
    ///
    /// It is NOT a diagnosis of the overtraining syndrome. The same consensus says that can only be
    /// made clinically — over months, by excluding infection, energy deficit, iron deficiency and the
    /// like — and that no single marker qualifies. The screen says exactly that and points to rest and,
    /// if it persists, to a doctor.
    public static func sustainedOverreaching(history: [WeeklyLoadBands],
                                             strengthEvidence: LaneEvidence,
                                             cardioEvidence: LaneEvidence,
                                             recovery: RecoveryReading) -> SustainedOverreaching? {
        guard recovery.state == .strained, history.count >= sustainedOverreachingWeeks else { return nil }

        func run(_ band: (WeeklyLoadBands) -> RelativeLoadBand?) -> Int {
            var count = 0
            for week in history.reversed() {
                guard band(week) == .muchHigher else { break }
                count += 1
            }
            return count
        }

        var lanes: [SustainedOverreaching.Lane] = []
        var weeks = 0
        let strengthRun = run { $0.strength }
        if strengthRun >= sustainedOverreachingWeeks, strengthEvidence == .falling {
            lanes.append(.strength)
            weeks = max(weeks, strengthRun)
        }
        let cardioRun = run { $0.cardio }
        if cardioRun >= sustainedOverreachingWeeks, cardioEvidence == .falling {
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
