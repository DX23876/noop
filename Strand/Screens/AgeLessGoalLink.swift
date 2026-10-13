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

    /// The template a lever turns into; nil for the measures without one yet (sleep consistency, strength and
    /// the two activity measures arrive with their own templates in stage 3).
    static func template(for c: HealthspanEngine.Component) -> GoalTemplateID? {
        switch c {
        case .sleepDuration: return .sleepAverage
        case .dailySteps: return .stepsAverage
        case .restingHR: return .sleepHeartRate
        case .vo2max: return .vo2max
        case .leanMass: return .bodyFat
        case .sleepConsistency, .zone13, .zone45, .strength: return nil
        }
    }

    /// The goal metrics that count as the same number as a measure, for "Goal running": a lean-mass lever is
    /// already served by a body-fat or a lean-mass goal.
    static func metrics(for c: HealthspanEngine.Component) -> Set<LongTermMetric> {
        switch c {
        case .sleepDuration: return [.sleepAverage]
        case .dailySteps: return [.stepsAverage]
        case .restingHR: return [.sleepHeartRate]
        case .vo2max: return [.vo2max]
        case .leanMass: return [.bodyFat, .leanMass]
        case .sleepConsistency, .zone13, .zone45, .strength: return []
        }
    }

    /// The open goal on the same number as `c`, if any.
    static func runningGoal(for c: HealthspanEngine.Component, in goals: [CoachGoal]) -> CoachGoal? {
        let wanted = metrics(for: c)
        return goals.first { goal in
            (goal.status == .active || goal.status == .paused) && goal.measure.map { wanted.contains($0.metric) } == true
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

    /// The AgeLess measure a goal's target speaks to, in that measure's unit; nil for a metric AgeLess does not
    /// read (a lean-mass goal is kept in kilograms, AgeLess in percent of body mass).
    static func agelessTarget(metric: LongTermMetric, target: Double) -> (component: HealthspanEngine.Component,
                                                                         value: Double)? {
        switch metric {
        case .sleepAverage: return (.sleepDuration, target)
        case .stepsAverage: return (.dailySteps, target)
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
        guard let metric = goal.measure?.metric, let target = goal.target,
              let mapped = agelessTarget(metric: metric, target: target),
              let years = HealthspanEngine.years(reaching: mapped.value, on: mapped.component, from: week),
              years <= -minimumYears else { return nil }
        return years
    }
}
