import Foundation
import StrandAnalytics

// AgeLessGoalLink.swift — fork feature "AgeLess", stage 2 (backlog plan HEALTHSPAN_AGE_PLAN, 2026-10-13): which
// catalog goal measures the same number as an AgeLess measure, what a lever pre-fills, and what a goal's target
// is worth in AgeLess. One table, read by the lever card, the goal setup and the goal page, so the three cannot
// pair a measure with different goals.

/// What a lever hands the goal setup: the template, and the lever's step in the goal's own units.
struct AgeLessGoalPrefill: Hashable {
    let template: GoalTemplateID
    /// The lever's new value, in the goal's units (body fat for a lean-mass lever).
    let leverValue: Double
    /// The size of the lever's step, always positive.
    let stepSize: Double
    let higherIsBetter: Bool
}

enum AgeLessGoalLink {

    /// The template a lever turns into. Every measure has one since stage 3.
    static func template(for c: HealthspanEngine.Component) -> GoalTemplateID? {
        switch c {
        case .sleepDuration: return .sleepAverage
        case .sleepConsistency: return .sleepConsistency
        case .dailySteps: return .stepsAverage
        case .zone13: return .moderateWeekly
        case .zone45: return .vigorousWeekly
        case .strength: return .strengthMinutesWeekly
        case .restingHR: return .sleepHeartRate
        case .vo2max: return .vo2max
        case .leanMass: return .bodyFat
        }
    }

    /// The templates that count as the same number as a measure, for "Goal running": a lean-mass lever is
    /// already served by a body-fat or a lean-mass goal. Templates, not metrics, because the three weekly
    /// rhythms share one metric and differ only in what their weeks count.
    static func templates(for c: HealthspanEngine.Component) -> Set<GoalTemplateID> {
        switch c {
        case .leanMass: return [.bodyFat, .leanMass]
        default: return template(for: c).map { [$0] } ?? []
        }
    }

    /// The open goal on the same number as `c`, if any.
    static func runningGoal(for c: HealthspanEngine.Component, in goals: [CoachGoal]) -> CoachGoal? {
        let wanted = templates(for: c)
        return goals.first { goal in
            (goal.status == .active || goal.status == .paused)
                && goal.templateId.flatMap(GoalTemplateID.init(rawValue:)).map { wanted.contains($0) } == true
        }
    }

    /// The prefill for a lever; nil when the measure has no template yet.
    static func prefill(for lever: HealthspanEngine.Lever) -> AgeLessGoalPrefill? {
        guard let template = template(for: lever.component) else { return nil }
        // Lean mass is 100 % minus body fat, so its step is body fat's step the other way.
        let lean = lever.component == .leanMass
        let value = lean ? 100 - lever.newValue : lever.newValue
        let higher = lean ? false : lever.newValue > lever.currentValue
        return AgeLessGoalPrefill(template: template, leverValue: value,
                                  stepSize: abs(lever.newValue - lever.currentValue), higherIsBetter: higher)
    }

    /// The pre-filled target: the further of the lever's value and the goal's own current value plus the
    /// lever's step, so the goal is never reached on the day it is set and never asks less than the lever.
    /// Rounded to the template's `step` in the ambitious direction, then held inside `range`.
    static func target(_ p: AgeLessGoalPrefill, goalCurrent: Double?, step: Double,
                       range: ClosedRange<Double>) -> Double {
        var value = p.leverValue
        if let goalCurrent {
            value = p.higherIsBetter ? max(value, goalCurrent + p.stepSize) : min(value, goalCurrent - p.stepSize)
        }
        let rounded = step > 0 ? ((value / step).rounded(p.higherIsBetter ? .up : .down)) * step : value
        return min(range.upperBound, max(range.lowerBound, rounded))
    }

    /// A weekly AgeLess activity metric's amount per week over `from ..< to` (whole weeks): strength minutes from
    /// the sessions AgeLess counts as strength, moderate and vigorous minutes from what AgeLess banked. Nil for any
    /// other metric, or for the banked two while AgeLess is off. What the goal setup pre-fills from.
    static func recentPerWeek(_ metric: PeriodMetric, inputs: PeriodGoalInputs, from: Date, to: Date) -> Double? {
        let weeks = max(1, (to.timeIntervalSince(from) / (7 * 86_400)).rounded())
        switch metric {
        case .strengthMinutes:
            return inputs.workouts.filter {
                let date = Date(timeIntervalSince1970: Double($0.startTs))
                return date >= from && date < to && HealthspanWindow.countsAsStrength(storedName: $0.sport)
            }.compactMap { PeriodGoalTracker.workoutAmount(.strengthMinutes, $0) }.reduce(0, +) / weeks
        case .moderateMinutes, .vigorousMinutes:
            let fromKey = Repository.localDayKey(from), toKey = Repository.localDayKey(to)
            return inputs.agelessMinutes(for: metric)
                .map { $0.filter { $0.key >= fromKey && $0.key < toKey }.values.reduce(0, +) / weeks }
        default:
            return nil
        }
    }

    /// The AgeLess measure a goal's target speaks to, in that measure's unit; nil for a template AgeLess does
    /// not read (a lean-mass goal is kept in kilograms, AgeLess in percent of body mass). A weekly rhythm's
    /// target is its weekly amount, the unit AgeLess rates those measures in.
    static func agelessTarget(template: GoalTemplateID, target: Double) -> (component: HealthspanEngine.Component,
                                                                           value: Double)? {
        switch template {
        case .sleepAverage: return (.sleepDuration, target)
        case .sleepConsistency: return (.sleepConsistency, target)
        case .stepsAverage: return (.dailySteps, target)
        case .moderateWeekly: return (.zone13, target)
        case .vigorousWeekly: return (.zone45, target)
        case .strengthMinutesWeekly: return (.strength, target)
        case .sleepHeartRate: return (.restingHR, target)
        case .vo2max: return (.vo2max, target)
        case .bodyFat: return (.leanMass, 100 - target)
        default: return nil
        }
    }

    /// Smallest effect a goal's AgeLess line states.
    static let minimumYears = 0.1

    /// The years a goal's target would take off the AgeLess age of `week`: nil while AgeLess cannot price the
    /// goal, the week already meets the target, or the effect is under `minimumYears`. The same rule the levers
    /// use (`HealthspanEngine.years(reaching:on:from:)`), so a goal and its lever name the same years.
    static func years(goal: CoachGoal, week: HealthspanEngine.Inputs) -> Double? {
        guard let template = goal.templateId.flatMap(GoalTemplateID.init(rawValue:)), let target = goal.target,
              let mapped = agelessTarget(template: template, target: target),
              let years = HealthspanEngine.years(reaching: mapped.value, on: mapped.component, from: week),
              years <= -minimumYears else { return nil }
        return years
    }
}
