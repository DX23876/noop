import Foundation

// MARK: - One reading of a lane's load, used by every surface that shows it
//
// `TrainingLoad.relativeLoad` answers "how does the last week compare with your usual". This file turns
// that comparison into the ONE band every surface shows — the hero, the eight-week strip, the ratio
// chart, the overload warning and the page's sentence — so no screen classifies a load on its own.
//
// The band is always read on the same axis: the last seven days' mean daily load over the preceding
// baseline's (the uncoupled ratio `LoadTrend.ratio`). What changes with maturity is only where its
// edges sit:
//
//   • PROVISIONAL, until eight complete weeks exist: below under 0.75, usual up to 1.15, above up to
//     1.44, well above beyond. 0.75 and 1.44 are Polar's 0.8 and 1.3 (Training Load Pro white paper,
//     2025), converted to NOOP's windows: Polar's 28-day tolerance CONTAINS the acute week, so a coupled
//     ratio r = 4u / (u + 3) of the uncoupled u used here. 1.15 is NOOP's own choice: Polar calls
//     anything above 1.0 progression, which would make an ordinary +3 % week "above usual".
//   • PERSONAL, from eight complete weeks: the robust weekly range of `TrainingLoad.relativeLoad`,
//     expressed on the same ratio axis, held between two limits. "Well above" starts no later than
//     1.44, so a wearer who trains irregularly never has a large jump read as normal, and no earlier
//     than 1.15, so a very regular history's tiny spread cannot make +13 % "well above"; "below" starts
//     no earlier than 0.90.
//
// Days the data could not price leave both windows (`ComparisonCoverage.lane`) while at least five of the
// seven recent days and three quarters of the baseline are known. All-or-nothing windows blanked a lane
// for five weeks after one session without a usable heart-rate trace.
//
// Three guards sit on top of the edges:
//
//   • TOO FEW SESSIONS — fewer than three sessions in the baseline and there is no band at all; a first
//     or second session is not a pattern to be above or below (Polar requires the same three).
//   • LOW VOLUME — while the baseline sits under the WHO minimum (150 cardio minutes, or two strength days,
//     a week), a lane can read "above" but never "well above": doubling one session a week is a return to
//     training, not an overload (Polar shows "productive" instead of "overreaching" below the WHO level).
//   • HYSTERESIS — a band is only left once the ratio clears its edge by five percentage points, so a
//     week that sits on an edge does not change its label every day. Each day's band replays a fixed
//     fourteen-day warm-up rather than the whole history, which keeps a reading a function of a bounded
//     window: history older than `dependencyDays` can never move it.

/// Which lane a reading belongs to. The two lanes share the engine but not their guards or timings.
public enum TrainingLaneKind: String, Sendable, Codable, CaseIterable {
    case strength, cardio
}

/// What was done on each day beside the load figure itself — enough for the guards to tell a sparse
/// history from a real one. Days without an entry had no session.
public struct LaneActivity: Equatable, Sendable {
    public let sessionsByDay: [String: Int]
    public let minutesByDay: [String: Double]

    public init(sessionsByDay: [String: Int], minutesByDay: [String: Double] = [:]) {
        self.sessionsByDay = sessionsByDay
        self.minutesByDay = minutesByDay
    }

    public static let none = LaneActivity(sessionsByDay: [:])
}

/// Where the band edges sit on the ratio axis for one day.
public struct LaneThresholds: Equatable, Sendable {
    /// Below this ratio the band is `.below`.
    public let below: Double
    /// Above this ratio the band is `.higher`.
    public let above: Double
    /// Above this ratio the band is `.muchHigher`.
    public let wellAbove: Double
    /// True when the edges come from the wearer's own weekly variation.
    public let isPersonal: Bool

    public init(below: Double, above: Double, wellAbove: Double, isPersonal: Bool) {
        self.below = below
        self.above = above
        self.wellAbove = wellAbove
        self.isPersonal = isPersonal
    }
}

/// Which guard shaped a reading.
public enum LaneGuard: String, Equatable, Sendable, Codable {
    case none
    /// Fewer than `LaneEngine.minimumBaselineSessions` sessions in the baseline: no band.
    case tooFewSessions
    /// Baseline under the WHO minimum: the band stops at `.higher`.
    case lowVolumeCap
}

/// One lane's load, as every surface shows it.
public struct LaneReading: Equatable, Sendable {
    /// The day the reading describes (see `LaneEngine.readingDay`).
    public let day: String
    public let relative: RelativeLoadReading
    public let thresholds: LaneThresholds?
    /// Nil while there is no comparison, or while the guard withholds one.
    public let band: RelativeLoadBand?
    public let guardState: LaneGuard
    /// Consecutive days, ending on `day`, spent in the below band (at most `LaneEngine.belowRunLookbackDays`).
    public let daysBelowUsual: Int
    /// True when at least half of the fourteen days before `day` were above or well above usual.
    public let followsHighPhase: Bool

    public init(day: String, relative: RelativeLoadReading, thresholds: LaneThresholds?, band: RelativeLoadBand?,
                guardState: LaneGuard, daysBelowUsual: Int, followsHighPhase: Bool) {
        self.day = day
        self.relative = relative
        self.thresholds = thresholds
        self.band = band
        self.guardState = guardState
        self.daysBelowUsual = daysBelowUsual
        self.followsHighPhase = followsHighPhase
    }

    public var trend: LoadTrend? { relative.trend }

    /// The same reading with another band — for screenshot QA overrides, never for analysis.
    public func replacingBand(_ band: RelativeLoadBand?) -> LaneReading {
        LaneReading(day: day, relative: relative, thresholds: thresholds, band: band, guardState: guardState,
                    daysBelowUsual: daysBelowUsual, followsHighPhase: followsHighPhase)
    }
}

/// The performance evidence a verdict may use: e1RM for strength, the cardio evidence chain for cardio.
public enum LaneEvidence: String, Equatable, Sendable, Codable {
    case rising, unclear, falling
    /// No usable performance evidence: a verdict can only describe the load.
    case none

    public init(_ response: StrengthResponse) {
        switch response {
        case .rising: self = .rising
        case .unclear: self = .unclear
        case .falling: self = .falling
        case .unknown: self = .none
        }
    }

    public init(_ direction: FitnessDirection) {
        switch direction {
        case .improving: self = .rising
        case .unclear: self = .unclear
        case .worsening: self = .falling
        case .unknown: self = .none
        }
    }
}

/// What the page may say about one lane: a judgement when performance evidence supports one, otherwise
/// only a description of the load.
public enum LaneVerdict: Equatable, Sendable {
    case status(TrainingStatus)
    case loadOnly(RelativeLoadBand)
}

public enum LaneEngine {

    // MARK: Edges

    /// Polar's 0.8 on NOOP's uncoupled windows.
    public static let provisionalBelow = 0.75
    /// NOOP's own upper edge of "usual".
    public static let provisionalAbove = 1.15
    /// Polar's 1.3 on NOOP's uncoupled windows; also the latest a personal "well above" may start.
    public static let wellAboveCeiling = 1.44

    public static let provisionalThresholds = LaneThresholds(below: provisionalBelow, above: provisionalAbove,
                                                             wellAbove: wellAboveCeiling, isPersonal: false)

    /// The earliest a personal "well above" may start. A very regular history has a tiny weekly spread,
    /// and without a floor +13 % would read "well above usual"; it may not come sooner than the
    /// provisional "above".
    public static let personalWellAboveFloor = provisionalAbove
    /// The earliest a personal "below usual" may start: a week has to be at least 10 % light.
    public static let personalBelowCeiling = 0.90

    // MARK: Guards

    /// Sessions the baseline must hold before any band is shown.
    public static let minimumBaselineSessions = 3
    /// WHO weekly minimum of moderate aerobic activity, in minutes.
    public static let whoCardioMinutesPerWeek = 150.0
    /// WHO weekly minimum of muscle-strengthening days.
    public static let whoStrengthDaysPerWeek = 2.0
    /// How far past an edge the ratio must go before a band is left.
    public static let hysteresisMargin = 0.05
    /// Days replayed before each day's band, from a fresh start.
    public static let hysteresisWarmupDays = 14

    // MARK: Runs

    /// How far back a run of below-usual days is counted.
    public static let belowRunLookbackDays = 60
    /// Days before a reading that decide whether it follows a high phase.
    public static let highPhaseLookbackDays = 14
    /// Share of those days that must have been above or well above usual.
    public static let highPhaseMinimumShare = 0.5

    /// Days of the daily series a reading depends on, counting its own day. Data older than this cannot
    /// move it: the longest run looked back over, its warm-up, and each day's eight-week comparison.
    public static let dependencyDays = TrainingLoad.personalBaselineWeeks * TrainingLoad.recentWindow
        + hysteresisWarmupDays + belowRunLookbackDays - 1

    // MARK: - The reading day

    /// The day a current reading describes: today once something was logged today, otherwise yesterday.
    ///
    /// A day that has not happened yet is not a rest day. Reading through it put a zero into the recent
    /// week every morning and took it out again after the session, so the same week read −14 % before
    /// breakfast and +14 % after training.
    public static func readingDay(today: String, hasActivityToday: Bool) -> String {
        hasActivityToday ? today : WeeklyDigestEngine.addDays(today, -1)
    }

    // MARK: - Edges for one day

    /// The band edges for a comparison, or nil while there is none.
    public static func thresholds(for relative: RelativeLoadReading) -> LaneThresholds? {
        guard let trend = relative.trend else { return nil }
        guard relative.maturity == .personalBaseline, let range = relative.personalRange else {
            return provisionalThresholds
        }
        let week = trend.baselinePerDay * Double(TrainingLoad.recentWindow)
        guard week > 0 else { return provisionalThresholds }
        let wellAbove = min(max(range.muchHigherBound / week, personalWellAboveFloor), wellAboveCeiling)
        let above = min(range.usualUpperBound / week, wellAbove)
        let below = min(range.usualLowerBound / week, personalBelowCeiling, above)
        return LaneThresholds(below: below, above: above, wellAbove: wellAbove, isPersonal: true)
    }

    /// The band a ratio falls in, before any guard or hysteresis.
    public static func band(ratio: Double, thresholds: LaneThresholds) -> RelativeLoadBand {
        if ratio < thresholds.below { return .below }
        if ratio <= thresholds.above { return .usual }
        if ratio <= thresholds.wellAbove { return .higher }
        return .muchHigher
    }

    // MARK: - Readings

    /// One lane's reading through `day`.
    public static func reading(dailyByDay: [String: Double], unknownDays: Set<String> = [],
                               activity: LaneActivity, lane: TrainingLaneKind,
                               through day: String) -> LaneReading {
        readings(dailyByDay: dailyByDay, unknownDays: unknownDays, activity: activity, lane: lane,
                 days: [day])[0]
    }

    /// Readings for several days at once, sharing one pass over the daily comparisons. Same order as `days`.
    public static func readings(dailyByDay: [String: Double], unknownDays: Set<String> = [],
                                activity: LaneActivity, lane: TrainingLaneKind,
                                days: [String]) -> [LaneReading] {
        var timeline = Timeline(dailyByDay: dailyByDay, unknownDays: unknownDays, activity: activity, lane: lane)
        return days.map { timeline.reading(through: $0) }
    }

    /// Whether a lane's history at `day` counts as a high phase: at least half of the preceding
    /// `highPhaseLookbackDays` days above or well above usual.
    static func isHighPhase(_ bands: [RelativeLoadBand?]) -> Bool {
        let high = bands.filter { $0 == .higher || $0 == .muchHigher }.count
        return Double(high) >= Double(highPhaseLookbackDays) * highPhaseMinimumShare
    }

    /// The daily bands behind a set of readings, memoised so a week of readings replays each day once.
    private struct Timeline {
        let dailyByDay: [String: Double]
        let unknownDays: Set<String>
        let activity: LaneActivity
        let lane: TrainingLaneKind

        private struct Raw {
            let relative: RelativeLoadReading
            let thresholds: LaneThresholds?
            let band: RelativeLoadBand?
            let guardState: LaneGuard
        }

        private var raws: [String: Raw] = [:]
        private var bands: [String: RelativeLoadBand?] = [:]

        init(dailyByDay: [String: Double], unknownDays: Set<String>, activity: LaneActivity,
             lane: TrainingLaneKind) {
            self.dailyByDay = dailyByDay
            self.unknownDays = unknownDays
            self.activity = activity
            self.lane = lane
        }

        mutating func reading(through day: String) -> LaneReading {
            let raw = raw(day)
            var run = 0
            var cursor = day
            while run < LaneEngine.belowRunLookbackDays, band(cursor) == .below {
                run += 1
                cursor = WeeklyDigestEngine.addDays(cursor, -1)
            }
            var previous: [RelativeLoadBand?] = []
            cursor = day
            for _ in 0..<LaneEngine.highPhaseLookbackDays {
                cursor = WeeklyDigestEngine.addDays(cursor, -1)
                previous.append(band(cursor))
            }
            return LaneReading(day: day, relative: raw.relative, thresholds: raw.thresholds,
                               band: band(day), guardState: raw.guardState, daysBelowUsual: run,
                               followsHighPhase: LaneEngine.isHighPhase(previous))
        }

        /// The band shown for `day`: the guarded raw band, replayed through the warm-up with hysteresis.
        private mutating func band(_ day: String) -> RelativeLoadBand? {
            if let cached = bands[day] { return cached }
            guard raw(day).band != nil else {
                bands[day] = .some(nil)
                return nil
            }
            var held: RelativeLoadBand?
            var cursor = WeeklyDigestEngine.addDays(day, -LaneEngine.hysteresisWarmupDays)
            for _ in 0...LaneEngine.hysteresisWarmupDays {
                let entry = raw(cursor)
                if let next = entry.band, let ratio = entry.relative.trend?.ratio,
                   let thresholds = entry.thresholds {
                    if let current = held, current != next {
                        if LaneEngine.leaves(current, towards: next, ratio: ratio, thresholds: thresholds) {
                            held = next
                        }
                    } else {
                        held = next
                    }
                } else {
                    held = nil
                }
                cursor = WeeklyDigestEngine.addDays(cursor, 1)
            }
            let result = LaneEngine.capped(held, by: raw(day).guardState)
            bands[day] = .some(result)
            return result
        }

        private mutating func raw(_ day: String) -> Raw {
            if let cached = raws[day] { return cached }
            let relative = TrainingLoad.relativeLoad(dailyByDay: dailyByDay, through: day,
                                                     unknownDays: unknownDays, coverage: .lane)
            let thresholds = LaneEngine.thresholds(for: relative)
            var guardState = LaneGuard.none
            var band: RelativeLoadBand?
            if let ratio = relative.trend?.ratio, let thresholds {
                guardState = LaneEngine.guardState(relative: relative, activity: activity, lane: lane,
                                                   through: day)
                if guardState != .tooFewSessions {
                    band = LaneEngine.capped(LaneEngine.band(ratio: ratio, thresholds: thresholds),
                                             by: guardState)
                }
            }
            let entry = Raw(relative: relative, thresholds: thresholds, band: band, guardState: guardState)
            raws[day] = entry
            return entry
        }
    }

    /// Whether a ratio has gone far enough past the held band's edge to move to `next`.
    static func leaves(_ held: RelativeLoadBand, towards next: RelativeLoadBand, ratio: Double,
                       thresholds: LaneThresholds) -> Bool {
        if rank(next) > rank(held) {
            guard let edge = upperEdge(held, thresholds) else { return true }
            return ratio > edge + hysteresisMargin
        }
        guard let edge = lowerEdge(held, thresholds) else { return true }
        return ratio < edge - hysteresisMargin
    }

    private static func rank(_ band: RelativeLoadBand) -> Int {
        switch band {
        case .below: return 0
        case .usual: return 1
        case .higher: return 2
        case .muchHigher: return 3
        }
    }

    private static func upperEdge(_ band: RelativeLoadBand, _ t: LaneThresholds) -> Double? {
        switch band {
        case .below: return t.below
        case .usual: return t.above
        case .higher: return t.wellAbove
        case .muchHigher: return nil
        }
    }

    private static func lowerEdge(_ band: RelativeLoadBand, _ t: LaneThresholds) -> Double? {
        switch band {
        case .below: return nil
        case .usual: return t.below
        case .higher: return t.above
        case .muchHigher: return t.wellAbove
        }
    }

    static func capped(_ band: RelativeLoadBand?, by guardState: LaneGuard) -> RelativeLoadBand? {
        guardState == .lowVolumeCap && band == .muchHigher ? .higher : band
    }

    // MARK: - Guards

    /// The guard for a comparison through `day`, read from the same baseline days the ratio compares with.
    static func guardState(relative: RelativeLoadReading, activity: LaneActivity, lane: TrainingLaneKind,
                           through day: String) -> LaneGuard {
        let baselineDays = relative.maturity == .earlyEstimate ? 14 : TrainingLoad.baselineWindow
        var cursor = WeeklyDigestEngine.addDays(day, -TrainingLoad.recentWindow)
        var sessions = 0
        var minutes = 0.0
        var trainingDays = 0
        for _ in 0..<baselineDays {
            let count = activity.sessionsByDay[cursor] ?? 0
            sessions += count
            if count > 0 { trainingDays += 1 }
            minutes += activity.minutesByDay[cursor] ?? 0
            cursor = WeeklyDigestEngine.addDays(cursor, -1)
        }
        guard sessions >= minimumBaselineSessions else { return .tooFewSessions }
        let weeks = Double(baselineDays) / Double(TrainingLoad.recentWindow)
        switch lane {
        case .cardio:
            return minutes / weeks < whoCardioMinutesPerWeek ? .lowVolumeCap : .none
        case .strength:
            return Double(trainingDays) / weeks < whoStrengthDaysPerWeek ? .lowVolumeCap : .none
        }
    }

    // MARK: - Verdict

    /// Days below usual before a lane with no falling performance is called detraining.
    public static func detrainingAfterDays(_ lane: TrainingLaneKind) -> Int {
        lane == .strength ? TrainingStatusModel.strengthDetrainingAfterDays
                          : TrainingStatusModel.cardioDetrainingAfterDays
    }

    /// The verdict table. The same for both lanes; only the evidence and the detraining wait differ.
    ///
    /// | band       | rising                        | unclear                          | falling       | no evidence                          |
    /// |------------|-------------------------------|----------------------------------|---------------|--------------------------------------|
    /// | below      | maintaining                   | maintaining → detraining†        | detraining    | "less than usual" → detraining†      |
    /// | usual      | productive                    | maintaining                      | unproductive  | "as usual"                           |
    /// | above      | productive                    | maintaining                      | unproductive  | "more than usual"                    |
    /// | well above | productive if recovery holds, | unproductive if recovery holds,  | overreaching  | overreaching if recovery is strained,|
    /// |            | otherwise overreaching        | otherwise overreaching           |               | otherwise "much more than usual"     |
    ///
    /// † once the lane has been below usual for `detrainingAfterDays` — 21 days for strength (Bosquet et
    /// al. 2013), 14 for cardio (Mujika & Padilla 2000). Below usual straight after a high phase is
    /// `recovering` whatever the evidence says. Without evidence the table describes the load and claims
    /// nothing about what it did: "productive" needs a measured improvement, never load alone.
    public static func verdict(band: RelativeLoadBand, evidence: LaneEvidence, recovery: RecoveryState,
                               followsHighPhase: Bool, daysBelowUsual: Int,
                               lane: TrainingLaneKind) -> LaneVerdict {
        let longBelow = daysBelowUsual >= detrainingAfterDays(lane)
        switch band {
        case .below:
            if followsHighPhase { return .status(.recovering) }
            switch evidence {
            case .rising: return .status(.maintaining)
            case .unclear: return .status(longBelow ? .detraining : .maintaining)
            case .falling: return .status(.detraining)
            case .none: return longBelow ? .status(.detraining) : .loadOnly(.below)
            }
        case .usual, .higher:
            switch evidence {
            case .rising: return .status(.productive)
            case .unclear: return .status(.maintaining)
            case .falling: return .status(.unproductive)
            case .none: return .loadOnly(band)
            }
        case .muchHigher:
            let holding = recovery == .holding
            switch evidence {
            case .rising: return .status(holding ? .productive : .overreaching)
            case .unclear: return .status(holding ? .unproductive : .overreaching)
            case .falling: return .status(.overreaching)
            case .none: return recovery == .strained ? .status(.overreaching) : .loadOnly(.muchHigher)
            }
        }
    }

    /// The verdict for a reading, or nil while the reading has no band.
    public static func verdict(_ reading: LaneReading, evidence: LaneEvidence, recovery: RecoveryState,
                               lane: TrainingLaneKind) -> LaneVerdict? {
        guard let band = reading.band else { return nil }
        return verdict(band: band, evidence: evidence, recovery: recovery,
                       followsHighPhase: reading.followsHighPhase, daysBelowUsual: reading.daysBelowUsual,
                       lane: lane)
    }
}
