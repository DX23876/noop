import Foundation

/// The form a long-term goal takes on its page: what the big number is, which three figures sit under
/// it, which band follows and how its state is judged. Derived from what the goal measures, never
/// stored, so a goal cannot carry a shape that contradicts its metric.
enum GoalShape: String, CaseIterable {
    /// A total collected toward a target ("642 of 1,000 km").
    case sum
    /// A value moving from a start toward a target ("96.2 kg, target 80").
    case target
    /// A value held inside a band ("80 kg, plus or minus 1").
    case maintain
    /// The best effort since the goal started ("longest run 14.2 km").
    case best
    /// A weekly rhythm kept over many weeks ("3 a week, 86 % of weeks").
    case consistency
    /// A rolling mean ("7 h 34 min over 28 nights").
    case average
}

/// What a catalog goal measures. One case per distinct reading; the parameters (sport, band, window)
/// live on `GoalMeasureSpec`.
enum LongTermMetric: String, Codable, CaseIterable {
    case distanceTotal, minutesTotal, workoutsTotal, stepsTotal
    case longestDistance
    case paceAverage, hrvAverage, sleepAverage, recoveryAverage
    case weight, bodyFat, leanMass, waist, vo2max, restingHr
    case weeklyAdherence

    /// The shape before the maintain variant, which `GoalMeasureSpec.shape` adds from its band.
    var baseShape: GoalShape {
        switch self {
        case .distanceTotal, .minutesTotal, .workoutsTotal, .stepsTotal: return .sum
        case .longestDistance: return .best
        case .paceAverage, .hrvAverage, .sleepAverage, .recoveryAverage: return .average
        case .weight, .bodyFat, .leanMass, .waist, .vo2max, .restingHr: return .target
        case .weeklyAdherence: return .consistency
        }
    }
}

/// How a catalog goal is measured: the metric plus the few parameters a template lets the wearer set.
///
/// Stored on `CoachGoal.measure`. Every field decodes with a default so a later build can add one
/// without making older goals unreadable; an unreadable spec as a whole is kept verbatim by
/// `CoachGoal` (see `PreservedJSON`).
struct GoalMeasureSpec: Codable, Equatable {
    var metric: LongTermMetric
    /// Sport names a workout must match, as on `PeriodGoal.sportFilter`. Empty = every sport.
    var sportFilter: [String]
    /// Sum: the first day that counts. May lie before the goal was set ("1,000 km in 2026" set in
    /// October counts from January). Nil = the day the goal was set.
    var countFrom: Date?
    /// Maintain: the half-width of the band around the target.
    var band: Double?
    /// Consistency: how many recent weeks are judged for an open-ended goal.
    var adherenceWeeks: Int?
    /// Consistency: the share of judged weeks that counts as on track.
    var adherenceTarget: Double?
    /// Consistency: a fixed end instead of the rolling window.
    var fixedEnd: Date?
    /// Consistency: the weekly goal whose weeks this goal reads.
    var weeklyGoalId: UUID?

    init(metric: LongTermMetric, sportFilter: [String] = [], countFrom: Date? = nil, band: Double? = nil,
         adherenceWeeks: Int? = nil, adherenceTarget: Double? = nil, fixedEnd: Date? = nil,
         weeklyGoalId: UUID? = nil) {
        self.metric = metric
        self.sportFilter = sportFilter
        self.countFrom = countFrom
        self.band = band
        self.adherenceWeeks = adherenceWeeks
        self.adherenceTarget = adherenceTarget
        self.fixedEnd = fixedEnd
        self.weeklyGoalId = weeklyGoalId
    }

    private enum CodingKeys: String, CodingKey {
        case metric, sportFilter, countFrom, band, adherenceWeeks, adherenceTarget, fixedEnd, weeklyGoalId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metric = try c.decode(LongTermMetric.self, forKey: .metric)
        sportFilter = try c.decodeIfPresent([String].self, forKey: .sportFilter) ?? []
        countFrom = try c.decodeIfPresent(Date.self, forKey: .countFrom)
        band = try c.decodeIfPresent(Double.self, forKey: .band)
        adherenceWeeks = try c.decodeIfPresent(Int.self, forKey: .adherenceWeeks)
        adherenceTarget = try c.decodeIfPresent(Double.self, forKey: .adherenceTarget)
        fixedEnd = try c.decodeIfPresent(Date.self, forKey: .fixedEnd)
        weeklyGoalId = try c.decodeIfPresent(UUID.self, forKey: .weeklyGoalId)
    }

    var shape: GoalShape {
        if metric.baseShape == .target, band != nil { return .maintain }
        return metric.baseShape
    }
}

/// Which template a goal made before the catalog corresponds to (plan Q5). Only unambiguous matches:
/// a weight goal with a start and a target, a sleep goal, a train-regularly goal. Everything else keeps
/// being measured by its kind.
enum GoalTemplateAssignment {
    static func template(for goal: CoachGoal) -> GoalTemplateID? {
        guard goal.templateId == nil, goal.measure == nil,
              goal.status == .active || goal.status == .paused else { return nil }
        switch goal.kind {
        case .weight:
            guard let baseline = goal.baseline, let target = goal.target, baseline != target else { return nil }
            return target < baseline ? .weightLose : .weightGain
        case .sleep:
            return .sleepAverage
        case .consistency:
            return .trainingWeekly
        case .run, .strength, .hardSets, .stress, .recovery, .custom,
             .endurance, .fitness, .body, .activity, .habit:
            return nil
        }
    }
}

/// The catalog's templates by their stored ID. The ID is what `CoachGoal.templateId` keeps, so it never
/// changes once shipped; labels, suggestions and availability live with the catalog screens.
enum GoalTemplateID: String, CaseIterable {
    case distanceTotal = "endurance.distanceTotal"
    case timeTotal = "endurance.timeTotal"
    case workoutsTotal = "endurance.workoutsTotal"
    case longest = "endurance.longest"
    case event = "endurance.event"
    case paceAverage = "endurance.paceAverage"
    case trainingWeekly = "training.weekly"
    case setsWeekly = "strength.setsWeekly"
    case vo2max = "fitness.vo2max"
    case restingHr = "fitness.restingHr"
    case hrvAverage = "fitness.hrvAverage"
    case zoneWeekly = "fitness.zoneWeekly"
    case stepDays = "daily.stepDays"
    case stepsTotal = "daily.stepsTotal"
    case activeEnergyWeekly = "daily.activeEnergyWeekly"
    case trainingDays = "daily.trainingDays"
    case weightLose = "body.weightLose"
    case weightGain = "body.weightGain"
    case weightMaintain = "body.weightMaintain"
    case bodyFat = "body.bodyFat"
    case leanMass = "body.leanMass"
    case waist = "body.waist"
    case sleepAverage = "sleep.average"
    case sleepNightsWeekly = "sleep.nightsWeekly"
    case recoveryAverage = "recovery.average"
    case restDays = "recovery.restDays"
    case hydration = "habit.hydration"
    case journalHabit = "habit.journal"

    /// The kind the coach, the safety gates and the copy work with.
    var kind: CoachGoal.Kind {
        switch self {
        case .distanceTotal, .timeTotal, .workoutsTotal, .longest: return .endurance
        case .event, .paceAverage: return .run
        case .trainingWeekly: return .consistency
        case .setsWeekly: return .hardSets
        case .vo2max, .restingHr, .hrvAverage, .zoneWeekly: return .fitness
        case .stepDays, .stepsTotal, .activeEnergyWeekly, .trainingDays: return .activity
        // All three stay `.weight` so `GoalSafetyGate` judges their rate.
        case .weightLose, .weightGain, .weightMaintain: return .weight
        case .bodyFat, .leanMass, .waist: return .body
        case .sleepAverage, .sleepNightsWeekly: return .sleep
        case .recoveryAverage, .restDays: return .recovery
        case .hydration, .journalHabit: return .habit
        }
    }

    /// What the template measures. Weekly-rhythm templates all read their weekly goal's weeks.
    var metric: LongTermMetric {
        switch self {
        case .distanceTotal: return .distanceTotal
        case .timeTotal: return .minutesTotal
        case .workoutsTotal: return .workoutsTotal
        case .stepsTotal: return .stepsTotal
        case .longest, .event: return .longestDistance
        case .paceAverage: return .paceAverage
        case .hrvAverage: return .hrvAverage
        case .sleepAverage: return .sleepAverage
        case .recoveryAverage: return .recoveryAverage
        case .vo2max: return .vo2max
        case .restingHr: return .restingHr
        case .weightLose, .weightGain, .weightMaintain: return .weight
        case .bodyFat: return .bodyFat
        case .leanMass: return .leanMass
        case .waist: return .waist
        case .trainingWeekly, .setsWeekly, .zoneWeekly, .stepDays, .activeEnergyWeekly, .trainingDays,
             .sleepNightsWeekly, .restDays, .hydration, .journalHabit:
            return .weeklyAdherence
        }
    }
}
