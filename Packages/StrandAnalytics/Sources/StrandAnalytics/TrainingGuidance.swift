import Foundation
import WhoopProtocol

// MARK: - Training Load phase 2: what the training is for, and whether it was enough
//
// `LaneEngine` answers "too much?" against the wearer's own usual. This file adds the two questions the
// lanes cannot answer on their own (docs/fork/TRAINING_LOAD_PLAN.md §8):
//
//   • WHAT FOR. A wearer who walks a lot to lose weight is not training for a faster kilometre, and a lane
//     judged only by performance called that training wasted. `TrainingFocusResolver` reads the goal a lane
//     is measured against, and `GoalOutcome` judges the lane by it.
//   • ENOUGH? The WHO 2020 guideline (150 to 300 moderate minutes a week, or 75 to 150 vigorous, vigorous
//     counting double, and two muscle-strengthening days) as the floor for everyone, raised by the goal.
//     Intensity is measured against the wearer's own heart: 40 to 59 % of the heart-rate reserve is
//     moderate, 60 % and above vigorous (ACSM), so the same rule holds for every body size.
//
// Pure: every input is passed in, every day is a `yyyy-MM-dd` key, and nothing here reads a clock.

/// What a lane is measured against.
public enum TrainingFocus: String, Sendable, Codable, CaseIterable, Equatable {
    case loseWeight
    case fitness
    case strength
    case health
}

/// Where a lane's focus came from.
public enum TrainingFocusSource: String, Sendable, Codable, Equatable {
    /// The wearer chose it (Q3).
    case chosen
    /// The diet plan's direction.
    case dietPlan
    /// The weight goal's direction, without a diet plan.
    case weightGoal
    /// A training goal that measures this lane.
    case trainingGoal
    /// Nothing to go by: the guideline.
    case none
}

/// Why a goal is paused, as the goal stores it.
public enum TrainingGoalPause: String, Sendable, Codable, Equatable {
    case illness, pain, travel, life, other

    /// A pause that also rests the verdict and turns the morning advice to rest (Q22 rule 1).
    public var restsTheBody: Bool { self == .illness || self == .pain }
}

/// One lane's focus and what it rests on.
public struct TrainingFocusReading: Equatable, Sendable {
    public let focus: TrainingFocus
    public let source: TrainingFocusSource
    /// The day the deciding plan or goal began. A goal younger than `TrainingFocusResolver.graceDays` is only
    /// described (nil for a chosen focus or none).
    public let since: String?
    /// The deciding goal's current pause, if any.
    public let pause: TrainingGoalPause?

    public init(focus: TrainingFocus, source: TrainingFocusSource, since: String? = nil,
                pause: TrainingGoalPause? = nil) {
        self.focus = focus; self.source = source; self.since = since; self.pause = pause
    }

    public static let guideline = TrainingFocusReading(focus: .health, source: .none)
}

public enum TrainingFocusResolver {
    /// Days a new goal is only described before it judges a lane.
    public static let graceDays = 14

    /// A goal as the resolver needs it, with no dependency on the goal store.
    public struct Goal: Equatable, Sendable {
        public enum Kind: String, Sendable, Equatable {
            case weight, endurance, run, fitness, strength, hardSets, consistency, activity, other
        }
        public let kind: Kind
        public let baseline: Double?
        public let target: Double?
        public let targetDay: String?
        public let createdDay: String
        public let pause: TrainingGoalPause?

        public init(kind: Kind, baseline: Double?, target: Double?, targetDay: String?, createdDay: String,
                    pause: TrainingGoalPause? = nil) {
            self.kind = kind; self.baseline = baseline; self.target = target; self.targetDay = targetDay
            self.createdDay = createdDay; self.pause = pause
        }
    }

    /// The diet plan's direction, as `DietPlan.Goal` names it.
    public enum DietDirection: String, Sendable, Equatable { case lose, maintain, gain, recomp }

    private struct Candidate {
        let focus: TrainingFocus
        let source: TrainingFocusSource
        let since: String
        let targetDay: String?
        let pause: TrainingGoalPause?
        /// Diet plan first, then the weight goal, then training goals, among candidates without a date.
        let rank: Int
    }

    /// The focus a lane is judged by.
    ///
    /// Automatic (Q3): the diet plan's direction, else the weight goal's; a training goal speaks only for
    /// its own lane (endurance, running and fitness goals for cardio, strength and hard-set goals for
    /// strength, consistency and activity goals for cardio as health). Several candidates for one lane
    /// (Q9): the chosen focus, else the one with the nearest target date, else the plan before the weight
    /// goal before training goals. Nothing to go by: health, measured by the guideline.
    public static func resolve(lane: TrainingLaneKind, chosen: TrainingFocus?, diet: DietDirection?,
                               dietStartDay: String?, goals: [Goal], today: String) -> TrainingFocusReading {
        var candidates: [Candidate] = []
        if let diet, let start = dietStartDay {
            let focus: TrainingFocus
            switch diet {
            case .lose: focus = .loseWeight
            case .gain, .recomp: focus = .strength
            case .maintain: focus = .health
            }
            candidates.append(Candidate(focus: focus, source: .dietPlan, since: start, targetDay: nil, pause: nil,
                                        rank: 0))
        }
        for goal in goals {
            switch goal.kind {
            case .weight:
                guard diet == nil, let baseline = goal.baseline, let target = goal.target else { continue }
                let focus: TrainingFocus = target < baseline ? .loseWeight : (target > baseline ? .strength : .health)
                candidates.append(Candidate(focus: focus, source: .weightGoal, since: goal.createdDay,
                                            targetDay: goal.targetDay, pause: goal.pause, rank: 1))
            case .endurance, .run, .fitness:
                guard lane == .cardio else { continue }
                candidates.append(Candidate(focus: .fitness, source: .trainingGoal, since: goal.createdDay,
                                            targetDay: goal.targetDay, pause: goal.pause, rank: 2))
            case .strength, .hardSets:
                guard lane == .strength else { continue }
                candidates.append(Candidate(focus: .strength, source: .trainingGoal, since: goal.createdDay,
                                            targetDay: goal.targetDay, pause: goal.pause, rank: 2))
            case .consistency, .activity:
                guard lane == .cardio else { continue }
                candidates.append(Candidate(focus: .health, source: .trainingGoal, since: goal.createdDay,
                                            targetDay: goal.targetDay, pause: goal.pause, rank: 2))
            case .other:
                continue
            }
        }
        if let chosen {
            // A chosen focus still carries the pause of a goal that measures the same thing.
            let match = candidates.first { $0.focus == chosen }
            return TrainingFocusReading(focus: chosen, source: .chosen, since: nil, pause: match?.pause)
        }
        let dated = candidates.filter { ($0.targetDay ?? "") >= today && $0.targetDay != nil }
            .sorted { ($0.targetDay!, $0.rank) < ($1.targetDay!, $1.rank) }
        let pick = dated.first ?? candidates.sorted { $0.rank < $1.rank }.first
        guard let pick else { return .guideline }
        return TrainingFocusReading(focus: pick.focus, source: pick.source, since: pick.since, pause: pick.pause)
    }

    /// Whether a focus is still in its grace period on `today`.
    public static func isNew(_ reading: TrainingFocusReading, today: String) -> Bool {
        guard let since = reading.since else { return false }
        return since > WeeklyDigestEngine.addDays(today, -graceDays)
    }
}

// MARK: - Enough?

/// The weekly amount a focus asks for: the WHO floor, raised by the goal (Q6).
public struct EnoughTarget: Equatable, Sendable {
    /// Moderate-equivalent minutes a week (vigorous minutes count double).
    public let minutesLow: Int
    public let minutesHigh: Int
    public let strengthDaysLow: Int
    public let strengthDaysHigh: Int
    /// The WHO also asks those 65 and older for balance work on three days a week (Q21): a hint, no target.
    public let balanceHint: Bool
    /// The target came from the wearer's own weekly goal rather than the focus (Q33).
    public let fromOwnGoal: Bool

    public init(minutesLow: Int, minutesHigh: Int, strengthDaysLow: Int, strengthDaysHigh: Int,
                balanceHint: Bool = false, fromOwnGoal: Bool = false) {
        self.minutesLow = minutesLow; self.minutesHigh = minutesHigh
        self.strengthDaysLow = strengthDaysLow; self.strengthDaysHigh = strengthDaysHigh
        self.balanceHint = balanceHint; self.fromOwnGoal = fromOwnGoal
    }

    /// The WHO 2020 adult guideline.
    public static let guideline = EnoughTarget(minutesLow: 150, minutesHigh: 300, strengthDaysLow: 2, strengthDaysHigh: 2)

    /// The target for a focus, or nil under 18, where the WHO asks for 60 minutes a day and an adult target
    /// would be wrong (Q21). `ownWeeklyMinutes` is a weekly-minutes goal the wearer set, which wins (Q33).
    public static func forFocus(_ focus: TrainingFocus, age: Int?, ownWeeklyMinutes: Int? = nil) -> EnoughTarget? {
        if let age, age < 18 { return nil }
        let balance = (age ?? 0) >= 65
        var target: EnoughTarget
        switch focus {
        case .loseWeight:
            // ACSM 2009: more than 250 minutes a week for clinically significant loss; never under the floor.
            target = EnoughTarget(minutesLow: 250, minutesHigh: 300, strengthDaysLow: 2, strengthDaysHigh: 2,
                                  balanceHint: balance)
        case .strength:
            target = EnoughTarget(minutesLow: 150, minutesHigh: 300, strengthDaysLow: 2, strengthDaysHigh: 3,
                                  balanceHint: balance)
        case .fitness, .health:
            target = EnoughTarget(minutesLow: 150, minutesHigh: 300, strengthDaysLow: 2, strengthDaysHigh: 2,
                                  balanceHint: balance)
        }
        if let own = ownWeeklyMinutes, own > 0 {
            target = EnoughTarget(minutesLow: max(own, 0), minutesHigh: max(own, target.minutesHigh),
                                  strengthDaysLow: target.strengthDaysLow, strengthDaysHigh: target.strengthDaysHigh,
                                  balanceHint: balance, fromOwnGoal: true)
        }
        return target
    }
}

/// Active minutes of one day, as the daily pass stores them.
public struct ActiveMinutesDay: Equatable, Sendable, Codable {
    /// Inside a workout or recorded session, judged by heart rate alone.
    public var sessionModerate: Int
    public var sessionVigorous: Int
    /// Outside sessions, counted only where the strap measured steps in the same minute (Q20).
    public var everydayModerate: Int
    public var everydayVigorous: Int

    public init(sessionModerate: Int = 0, sessionVigorous: Int = 0, everydayModerate: Int = 0,
                everydayVigorous: Int = 0) {
        self.sessionModerate = sessionModerate; self.sessionVigorous = sessionVigorous
        self.everydayModerate = everydayModerate; self.everydayVigorous = everydayVigorous
    }

    /// Moderate-equivalent minutes: vigorous minutes count double (WHO 2020).
    public var equivalentMinutes: Int {
        sessionModerate + everydayModerate + 2 * (sessionVigorous + everydayVigorous)
    }

    public static let seriesKeys = (sessionModerate: "active_min_session_moderate",
                                    sessionVigorous: "active_min_session_vigorous",
                                    everydayModerate: "active_min_everyday_moderate",
                                    everydayVigorous: "active_min_everyday_vigorous")
}

public enum ActiveMinutes {
    /// Lower edge of moderate intensity, as a share of the heart-rate reserve (ACSM: 40 to 59 %).
    public static let moderateReserve = 0.40
    /// Lower edge of vigorous intensity (ACSM: 60 % and above).
    public static let vigorousReserve = 0.60
    /// Strap step ticks in a minute that count as moving. A slow walk is about 80 steps a minute; 30 keeps a
    /// stroll and excludes a raised pulse at a desk (stress, heat, fever), which must never count (Q20).
    public static let movementTicksPerMinute = 30
    /// Samples a minute needs before its heart rate is read. The strap writes about one a second.
    public static let minimumSamplesPerMinute = 10

    /// One day's active minutes. `sessions` are the spans of workouts and recorded sessions; a minute inside
    /// one counts by heart rate alone, a minute outside only with steps measured in that minute.
    public static func day(hr: [HRSample], steps: [StepSample], sessions: [ClosedRange<Int>],
                           restingHR: Double, maxHR: Double) -> ActiveMinutesDay {
        let reserve = maxHR - restingHR
        guard reserve > 10, !hr.isEmpty else { return ActiveMinutesDay() }
        var sums: [Int: (total: Int, count: Int)] = [:]
        for s in hr where s.bpm > 0 {
            let m = s.ts / 60
            let prior = sums[m] ?? (0, 0)
            sums[m] = (prior.total + s.bpm, prior.count + 1)
        }
        let ticks = ticksPerMinute(steps)
        var out = ActiveMinutesDay()
        for (minute, sum) in sums where sum.count >= minimumSamplesPerMinute {
            let bpm = Double(sum.total) / Double(sum.count)
            let share = (bpm - restingHR) / reserve
            guard share >= moderateReserve else { continue }
            let vigorous = share >= vigorousReserve
            let ts = minute * 60 + 30
            if sessions.contains(where: { $0.contains(ts) }) {
                if vigorous { out.sessionVigorous += 1 } else { out.sessionModerate += 1 }
            } else if (ticks[minute] ?? 0) >= movementTicksPerMinute {
                if vigorous { out.everydayVigorous += 1 } else { out.everydayModerate += 1 }
            }
        }
        return out
    }

    /// Locomotion ticks attributed to the minute of the later sample, by `StepsCounter`'s own rules.
    static func ticksPerMinute(_ samples: [StepSample]) -> [Int: Int] {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return [:] }
        let classed = StepsCounter.hasActivityClasses(sorted)
        var out: [Int: Int] = [:]
        for i in 1..<sorted.count {
            let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF
            guard StepsCounter.shouldCountDelta(activityClass: sorted[i].activityClass, hasActivityClasses: classed),
                  StepsCounter.isPlausibleDelta(previousTs: sorted[i - 1].ts, currentTs: sorted[i].ts, delta: delta)
            else { continue }
            out[sorted[i].ts / 60, default: 0] += delta
        }
        return out
    }

    /// A session the heart rate cannot speak for (no trace, a swim, or a wearer whose pulse does not show
    /// load): its minutes count by the wearer's rating (Q7, Q8, Q21). Moderate from 4 of 10, vigorous from 7
    /// (Borg CR10); unrated or easier, nothing, because a duration alone says nothing about intensity.
    public static func ratedMinutes(durationMinutes: Int, rating: Double?) -> (moderate: Int, vigorous: Int) {
        guard let rating, durationMinutes > 0 else { return (0, 0) }
        if rating >= 7 { return (0, durationMinutes) }
        if rating >= 4 { return (durationMinutes, 0) }
        return (0, 0)
    }
}

/// One week against its target.
public struct EnoughWeek: Equatable, Sendable {
    public enum State: String, Sendable, Codable { case below, within, above }
    /// The first day of the week.
    public let start: String
    public let equivalentMinutes: Int
    /// Of those, minutes outside sessions.
    public let everydayMinutes: Int
    /// Of those, minutes counted by a rating rather than heart rate.
    public let ratedMinutes: Int
    public let strengthDays: Int
    public let target: EnoughTarget
    /// The week is still running: a partial count is not yet "below".
    public let isComplete: Bool

    public init(start: String, equivalentMinutes: Int, everydayMinutes: Int, ratedMinutes: Int, strengthDays: Int,
                target: EnoughTarget, isComplete: Bool) {
        self.start = start; self.equivalentMinutes = equivalentMinutes; self.everydayMinutes = everydayMinutes
        self.ratedMinutes = ratedMinutes; self.strengthDays = strengthDays; self.target = target
        self.isComplete = isComplete
    }

    public var minutesState: State {
        if equivalentMinutes < target.minutesLow { return .below }
        if equivalentMinutes > target.minutesHigh { return .above }
        return .within
    }

    public var reachedMinutes: Bool { equivalentMinutes >= target.minutesLow }
    public var reachedStrength: Bool { strengthDays >= target.strengthDaysLow }

    /// Minutes still missing to the low end of the target, zero once reached.
    public var minutesToGo: Int { max(0, target.minutesLow - equivalentMinutes) }
}

public enum EnoughCount {
    /// How many of the last `weeks` complete weeks reached their minute target. A goal is carried when
    /// at least `carriedWeeks` of the last four did (Q: "in mindestens drei der letzten vier Wochen").
    public static let carriedWeeks = 3
    public static let windowWeeks = 4

    public static func weeksReached(_ weeks: [EnoughWeek]) -> (reached: Int, of: Int) {
        let complete = weeks.filter(\.isComplete).suffix(windowWeeks)
        return (complete.filter(\.reachedMinutes).count, complete.count)
    }

    public static func isCarried(_ weeks: [EnoughWeek]) -> Bool {
        let r = weeksReached(weeks)
        return r.of >= windowWeeks && r.reached >= carriedWeeks
    }
}

// MARK: - The verdict against the goal

/// What a lane's goal says beside or instead of the performance verdict.
public enum LaneGoalNote: String, Sendable, Codable, Equatable {
    /// Losing weight: the minutes came together in three of four weeks and recovery is not strained.
    case carriesWeightLoss
    /// Losing weight: strength held within `GoalOutcome.strengthHeldDrop` over six weeks.
    case strengthHeld
    /// No measurable goal: the guideline was met in three of four weeks.
    case meetsGuideline
    /// The goal is younger than two weeks: the lane is only described.
    case goalTooNew
    /// The goal is paused for illness or pain: the verdict rests.
    case paused
    /// Strength is falling fast while weight falls fast and recovery is strained: look at the load or the
    /// deficit. Never a medical statement.
    case checkLoadOrDeficit
}

/// One lane's verdict after the goal has spoken.
public struct LaneGoalReading: Equatable, Sendable {
    /// The verdict a screen shows when `note` does not replace it. Nil while it rests or there is none.
    public let verdict: LaneVerdict?
    public let note: LaneGoalNote?
    public let focus: TrainingFocusReading

    public init(verdict: LaneVerdict?, note: LaneGoalNote?, focus: TrainingFocusReading) {
        self.verdict = verdict; self.note = note; self.focus = focus
    }

    /// Whether the note is the headline in place of the verdict.
    public var noteIsHeadline: Bool {
        switch note {
        case .carriesWeightLoss, .strengthHeld, .meetsGuideline, .paused: return true
        case .goalTooNew, .checkLoadOrDeficit, nil: return false
        }
    }
}

public enum GoalOutcome {
    /// The largest fall in the main lifts over six weeks that still counts as strength held in a deficit (Q10).
    /// A 2022 meta-analysis found an energy deficit slows lean-mass gain far more than strength gain, and a
    /// session's estimated maximum moves by a few percent from one session to the next.
    public static let strengthHeldDrop = -5.0
    /// Weight falling faster than this share a week, together with falling strength and strained recovery,
    /// asks the wearer to look at the load or the deficit.
    public static let fastLossPercentPerWeek = 1.0

    /// Verdicts a goal note never overrides: a lane that is too much stays too much, and one losing form
    /// stays named as such.
    static func isProtected(_ verdict: LaneVerdict?) -> Bool {
        if case .status(let s) = verdict, s == .overreaching || s == .detraining { return true }
        return false
    }

    /// The cardio lane against its focus.
    public static func cardio(verdict: LaneVerdict?, band: RelativeLoadBand?, focus: TrainingFocusReading,
                              weeks: [EnoughWeek], recovery: RecoveryState, today: String) -> LaneGoalReading {
        if let pause = focus.pause, pause.restsTheBody {
            return LaneGoalReading(verdict: nil, note: .paused, focus: focus)
        }
        if TrainingFocusResolver.isNew(focus, today: today) {
            return LaneGoalReading(verdict: band.map { .loadOnly($0) }, note: .goalTooNew, focus: focus)
        }
        guard !isProtected(verdict) else { return LaneGoalReading(verdict: verdict, note: nil, focus: focus) }
        switch focus.focus {
        case .loseWeight where EnoughCount.isCarried(weeks) && recovery != .strained:
            return LaneGoalReading(verdict: verdict, note: .carriesWeightLoss, focus: focus)
        case .health where EnoughCount.isCarried(weeks) && recovery != .strained:
            return LaneGoalReading(verdict: verdict, note: .meetsGuideline, focus: focus)
        default:
            return LaneGoalReading(verdict: verdict, note: nil, focus: focus)
        }
    }

    /// The strength lane against its focus. `changePercent` is the main lifts' change over six weeks
    /// (`StrengthSession.recentChangePercent`); `weightChangePercentPerWeek` the weight trend, negative when
    /// falling.
    public static func strength(verdict: LaneVerdict?, band: RelativeLoadBand?, focus: TrainingFocusReading,
                                changePercent: Double?, weightChangePercentPerWeek: Double?,
                                recovery: RecoveryState, today: String) -> LaneGoalReading {
        if let pause = focus.pause, pause.restsTheBody {
            return LaneGoalReading(verdict: nil, note: .paused, focus: focus)
        }
        if TrainingFocusResolver.isNew(focus, today: today) {
            return LaneGoalReading(verdict: band.map { .loadOnly($0) }, note: .goalTooNew, focus: focus)
        }
        guard focus.focus == .loseWeight, let change = changePercent else {
            return LaneGoalReading(verdict: verdict, note: nil, focus: focus)
        }
        if change >= strengthHeldDrop {
            guard !isProtected(verdict) else { return LaneGoalReading(verdict: verdict, note: nil, focus: focus) }
            return LaneGoalReading(verdict: verdict, note: .strengthHeld, focus: focus)
        }
        if let loss = weightChangePercentPerWeek, -loss > fastLossPercentPerWeek, recovery == .strained {
            return LaneGoalReading(verdict: verdict, note: .checkLoadOrDeficit, focus: focus)
        }
        return LaneGoalReading(verdict: verdict, note: nil, focus: focus)
    }
}
