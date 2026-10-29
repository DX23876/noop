import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// A long-term goal on its way through the catalog setup (plan §9): the template, the value and time, the weekly
/// goal that drives it, and every suggestion read from the wearer's own data. Moved out of
/// `LongTermGoalSetupView` so the Android core builds the same goal from the same numbers (parity plan 2.3); the
/// views keep only what they show and how the wearer changes it.
struct LongTermGoalDraft {
    enum WeeklyChoice: String, CaseIterable { case workouts, stepDays }

    var template: GoalTemplate?
    var sportIndex = 0
    var target: Double = 0
    var baseline: Double = 0
    var countFromYearStart = true
    var endDate = Date()
    var hasDate = false
    var targetDate = Date()
    var openEnded = true
    var fixedWeeks = 12
    var weeklyOn = true
    var weeklyTarget: Double = 3
    var weeklyChoice: WeeklyChoice = .workouts
    var title = ""
    var motivation = ""
    var threshold: Double = 0
    var band: Double = 1
    var habitKey: String?
    var habitWantsYes = true

    /// What the suggestions read: every period-goal input, the level series, the last weigh-in.
    var inputs = PeriodGoalInputs()
    var series: [LongTermMetric: [GoalMilestones.Sample]] = [:]
    var currentWeight: Double?
    /// The profile's weight, the safety gate's fallback without a weigh-in.
    var profileWeightKg: Double = 0
    var now = Date()
    var calendar: Calendar = TrainingPreferences.weekCalendar

    var metric: LongTermMetric? { template?.id.metric }
    var weeklyMetric: PeriodMetric? { template?.id.weeklyMetric }

    var sportFilter: [String] {
        guard let template else { return [] }
        if template.id == .event || template.id == .paceAverage { return ["Running"] }
        guard template.sportChoices.indices.contains(sportIndex) else { return [] }
        return template.sportChoices[sportIndex].filter
    }

    func matchingRows() -> [WorkoutRow] {
        inputs.workouts.filter { GoalActionEvaluator.matches($0, any: sportFilter) }
    }

    /// What a workout adds to a sum goal: kilometres, minutes or one session.
    func amount(_ row: WorkoutRow) -> Double? {
        guard let metric else { return nil }
        return LongTermGoalReader.amount(metric, row)
    }

    var weekStart: Date { calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now }

    /// The amount per week over the last four complete weeks: kilometres, minutes, sessions or steps.
    var recentPerWeek: Double {
        let from = calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart
        if metric == .stepsTotal {
            let fromKey = StoreReader.localDayKey(from), toKey = StoreReader.localDayKey(weekStart)
            return Double(inputs.stepsByDay.filter { $0.key >= fromKey && $0.key < toKey }.values.reduce(0, +)) / 4
        }
        return matchingRows().filter {
            let date = Date(timeIntervalSince1970: Double($0.startTs))
            return date >= from && date < weekStart
        }.compactMap(amount).reduce(0, +) / 4
    }

    var recentSessionsPerWeek: Double {
        let from = calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart
        return Double(matchingRows().filter {
            let date = Date(timeIntervalSince1970: Double($0.startTs))
            return date >= from && date < weekStart
        }.count) / 4
    }

    var yearStart: Date {
        Calendar.autoupdatingCurrent.date(from: Calendar.autoupdatingCurrent.dateComponents([.year], from: now)) ?? now
    }

    var countFrom: Date { countFromYearStart ? yearStart : Calendar.autoupdatingCurrent.startOfDay(for: now) }

    var collectedSoFar: Double {
        guard countFromYearStart else { return 0 }
        if metric == .stepsTotal {
            let fromKey = StoreReader.localDayKey(countFrom)
            return Double(inputs.stepsByDay.filter { $0.key >= fromKey }.values.reduce(0, +))
        }
        let from = countFrom.timeIntervalSince1970
        return matchingRows().filter { Double($0.startTs) >= from }.compactMap(amount).reduce(0, +)
    }

    var weeksToEnd: Double { max(1, endDate.timeIntervalSince(now) / (7 * 86_400)) }

    var bestLast12Weeks: Double? {
        let from = now.addingTimeInterval(-84 * 86_400).timeIntervalSince1970
        return matchingRows().filter { Double($0.startTs) >= from }.compactMap(\.distanceM).max().map { $0 / 1_000 }
    }

    /// Where a target-value or average metric stands now, read the way its page will read it.
    var currentLevel: Double? {
        guard let metric else { return nil }
        switch metric {
        case .weight: return currentWeight ?? profileWeightKg
        case .bodyFat, .leanMass, .waist, .vo2max, .restingHr, .sleepHeartRate:
            let rule = LongTermGoalReader.levelRule(metric)
            return LongTermGoalMath.level(samples: series[metric] ?? [], now: now, windowDays: rule.windowDays,
                                          minValues: rule.minValues)?.value
        case .sleepAverage, .hrvAverage, .recoveryAverage, .stepsAverage:
            let values = inputs.days.sorted { $0.day < $1.day }.suffix(28).compactMap { day -> Double? in
                switch metric {
                case .sleepAverage: return day.totalSleepMin.map { $0 / 60 }
                case .stepsAverage: return day.steps.flatMap { $0 > 0 ? Double($0) : nil }
                case .hrvAverage: return day.avgHrv
                default: return day.recovery
                }
            }
            return values.count >= 7 ? values.reduce(0, +) / Double(values.count) : nil
        case .sleepConsistency:
            let from = calendar.date(byAdding: .day, value: -28, to: now) ?? now
            let values = (series[.sleepConsistency] ?? []).filter { $0.date >= from }.map(\.value)
            return values.count >= 7 ? values.reduce(0, +) / Double(values.count) : nil
        case .paceAverage:
            let runs = matchingRows().compactMap { row -> LongTermGoalMath.RunSample? in
                guard let meters = row.distanceM, meters > 0 else { return nil }
                return LongTermGoalMath.RunSample(date: Date(timeIntervalSince1970: Double(row.startTs)), distanceM: meters,
                                                  durationS: row.durationS ?? Double(max(0, row.endTs - row.startTs)))
            }
            return LongTermGoalMath.pace(runs: runs, now: now, windowDays: 56)?.secondsPerKm
        default: return nil
        }
    }

    /// Whether the start of a target-value goal comes from a measurement (then it is shown, not edited).
    var hasMeasuredStart: Bool {
        metric == .weight ? currentWeight != nil : currentLevel != nil
    }

    /// How a target-value or average metric moves in the stepper, and its sensible range.
    var levelStep: (step: Double, range: ClosedRange<Double>) {
        switch metric {
        case .weight?, .leanMass?: return (0.5, 30...400)
        case .bodyFat?: return (0.5, 3...60)
        case .waist?: return (1, 40...200)
        case .vo2max?: return (0.5, 15...90)
        case .restingHr?, .sleepHeartRate?: return (1, 30...110)
        case .stepsAverage?: return (500, 1_000...40_000)
        case .sleepConsistency?: return (1, 30...100)
        case .sleepAverage?: return (0.25, 5...10)
        case .hrvAverage?: return (1, 10...250)
        case .recoveryAverage?: return (1, 10...99)
        case .paceAverage?: return (5, 150...900)
        default: return (1, 0...10_000)
        }
    }

    /// The suggested change from where the wearer stands (plan §3, "Vorschlag beim Anlegen").
    func suggestedLevel(from current: Double) -> Double {
        guard let template else { return current }
        func round(_ v: Double, _ step: Double) -> Double { (v / step).rounded() * step }
        switch template.id {
        case .weightLose: return max(30, round(current - 5, 0.5))
        case .weightGain: return round(current + 3, 0.5)
        case .bodyFat: return max(3, round(current - 2, 0.5))
        case .leanMass: return round(current + 1, 0.5)
        case .waist: return round(current - 3, 1)
        case .vo2max: return round(current + 2, 0.5)
        case .restingHr, .sleepHeartRate: return round(current - 3, 1)
        case .stepsAverage: return max(1_000, round(current + 1_000, 500))
        case .sleepConsistency: return min(100, round(current + 10, 1))
        case .sleepAverage: return min(10, max(7.5, ((current + 0.25) * 4).rounded(.up) / 4))
        case .hrvAverage: return (current * 1.05).rounded()
        case .recoveryAverage: return min(99, (current + 5).rounded())
        case .paceAverage: return round(current - 15, 5)
        default: return current
        }
    }

    /// Sets the value step's numbers from the data, once per template.
    mutating func suggest() {
        guard let template else { return }
        title = template.title.localizedCatalogValue
        hasDate = false
        switch template.shape {
        case .sum:
            let thisYearEnd = Calendar.autoupdatingCurrent.date(byAdding: DateComponents(year: 1, day: -1), to: yearStart) ?? now
            endDate = thisYearEnd.timeIntervalSince(now) > 56 * 86_400
                ? thisYearEnd : Calendar.autoupdatingCurrent.date(byAdding: .month, value: 6, to: now) ?? now
            resuggestSum()
        case .best:
            let best = bestLast12Weeks ?? 0
            baseline = best
            target = [5.0, 10, 15, 21.1, 42.2].first { $0 > best } ?? (best + 5).rounded()
            if template.id == .event {
                hasDate = true
                targetDate = Calendar.autoupdatingCurrent.date(byAdding: .weekOfYear, value: 12, to: now) ?? now
            }
        case .target, .average:
            let current = currentLevel ?? (metric == .sleepAverage ? 7 : 0)
            // Started on the value's own step, so the first waypoint is a step away, not a fraction.
            baseline = template.shape == .target && metric != .weight
                ? (current / levelStep.step).rounded() * levelStep.step : current
            target = suggestedLevel(from: current)
            targetDate = safeDate()
        case .maintain:
            let current = currentLevel ?? 0
            baseline = (current * 10).rounded() / 10
            target = baseline
            band = 1
        case .consistency:
            openEnded = true
            threshold = weeklyMetric?.defaultThreshold ?? 0
            habitKey = nil
            habitWantsYes = true
            target = suggestedPerWeek()
        }
        if template.id == .stepDays { threshold = 10_000 }
        suggestWeekly()
    }

    /// The last four weeks' weekly amount of an AgeLess activity measure: strength minutes from the sessions
    /// AgeLess counts, moderate and vigorous minutes from what AgeLess banked. Nil without the data.
    var recentAgeLessPerWeek: Double? {
        let from = calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart
        return weeklyMetric.flatMap { AgeLessGoalLink.recentPerWeek($0, inputs: inputs, from: from, to: weekStart) }
    }

    /// The suggested weekly amount for a consistency template: the wearer's own level where one exists.
    func suggestedPerWeek() -> Double {
        switch weeklyMetric {
        case .workouts?: return recentSessionsPerWeek > 0 ? min(14, (recentSessionsPerWeek + 1).rounded()) : 3
        case .workingSets?:
            let from = StoreReader.localDayKey(calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart)
            let sets = (inputs.setsByDay ?? [:]).filter { $0.key >= from }.values.reduce(0, +) / 4
            return sets > 0 ? max(5, (sets / 5).rounded() * 5) : 40
        case .zoneMinutes?: return 150
        case .strengthMinutes?, .moderateMinutes?, .vigorousMinutes?:
            // The wearer's last four weeks, one step up; AgeLess's own target without history.
            guard let metric = weeklyMetric else { return 5 }
            let step = metric.step(for: .week)
            guard let recent = recentAgeLessPerWeek, recent > 0 else { return metric.defaultTarget(for: .week) }
            return min(metric.range(for: .week).upperBound, ((recent / step).rounded() + 1) * step)
        case .activeEnergy?:
            let from = StoreReader.localDayKey(calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart)
            let kcal = inputs.activeKcalByDay.filter { $0.key >= from }.values.reduce(0, +) / 4
            return kcal > 0 ? max(500, (kcal / 100).rounded() * 100) : 2_000
        case .restDays?: return 2
        default: return 5
        }
    }

    mutating func resuggestSum() {
        let projected = collectedSoFar + recentPerWeek * weeksToEnd
        let step = sumStep(projected)
        target = max(step, (projected / step).rounded(.up) * step)
    }

    /// Round numbers for a sum: 10 or 50 km, whole hours, 5 or 50 sessions, 10,000 or 100,000 steps.
    func sumStep(_ value: Double) -> Double {
        switch metric {
        case .minutesTotal?: return value >= 6_000 ? 600 : 60
        case .workoutsTotal?: return value >= 200 ? 50 : 5
        case .stepsTotal?: return value >= 1_000_000 ? 100_000 : 10_000
        default: return value >= 200 ? 50 : 10
        }
    }

    /// The date a weight change reaches at 0.5 kg a week, a pace the safety gate calls conservative.
    /// Other metrics get twelve weeks, a span the page can show a trend over.
    func safeDate() -> Date {
        guard metric == .weight else { return now.addingTimeInterval(12 * 7 * 86_400) }
        let weeks = max(4, abs(baseline - target) / 0.5)
        return now.addingTimeInterval(weeks * 7 * 86_400)
    }

    var hasLiftingLog: Bool { inputs.setsByDay != nil }

    mutating func suggestWeekly() {
        guard let template else { return }
        weeklyOn = true
        switch template.id {
        case .distanceTotal, .workoutsTotal:
            weeklyTarget = max(1, ((target - collectedSoFar) / weeksToEnd).rounded())
        case .timeTotal:
            // Minutes in tens: "681 min a week" is a precision nobody plans by.
            weeklyTarget = max(10, ((target - collectedSoFar) / weeksToEnd / 10).rounded() * 10)
        case .stepsTotal, .stepsAverage:
            weeklyTarget = 5
        case .longest, .event:
            weeklyTarget = max(5, recentKmPerWeek.rounded())
        case .weightLose, .weightMaintain:
            weeklyChoice = .workouts
            weeklyTarget = 3
        case .weightGain, .leanMass:
            weeklyTarget = hasLiftingLog ? 40 : 3
        case .bodyFat, .waist:
            weeklyTarget = 3
        case .vo2max, .restingHr, .sleepHeartRate:
            weeklyTarget = 150
        case .sleepAverage, .hrvAverage, .recoveryAverage:
            weeklyTarget = 5
        case .paceAverage:
            weeklyTarget = max(2, recentSessionsPerWeek.rounded())
        default:
            weeklyTarget = target
        }
    }

    var recentKmPerWeek: Double {
        let from = calendar.date(byAdding: .weekOfYear, value: -4, to: weekStart) ?? weekStart
        return matchingRows().filter {
            let date = Date(timeIntervalSince1970: Double($0.startTs))
            return date >= from && date < weekStart
        }.reduce(0) { $0 + ($1.distanceM ?? 0) / 1_000 } / 4
    }

    // MARK: - The goal it makes

    var shape: GoalShape? { template?.shape }

    func buildGoal(weeklyGoalId: UUID?) -> CoachGoal? {
        guard let template else { return nil }
        var spec = GoalMeasureSpec(metric: template.id.metric, sportFilter: sportFilter)
        var goalBaseline: Double? = baseline
        var date: Date? = hasDate ? targetDate : nil
        switch template.shape {
        case .sum:
            spec.countFrom = countFrom
            goalBaseline = 0
            date = endDate
        case .consistency:
            goalBaseline = nil
            spec.weeklyGoalId = weeklyGoalId
            spec.adherenceWeeks = LongTermGoalMath.adherenceWindowWeeks
            spec.adherenceTarget = LongTermGoalMath.adherenceTarget
            if !openEnded { spec.fixedEnd = now.addingTimeInterval(Double(fixedWeeks) * 7 * 86_400) }
            date = spec.fixedEnd
        case .maintain:
            spec.band = band
            date = nil
        case .average:
            date = nil
        case .best, .target:
            break
        }
        if template.id == .trainingWeekly { goalBaseline = recentSessionsPerWeek }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoachGoal(kind: template.id.kind, title: name.isEmpty ? template.title.localizedCatalogValue : name,
                         baseline: goalBaseline, target: target, targetDate: date,
                         motivation: motivation.trimmingCharacters(in: .whitespacesAndNewlines),
                         templateId: template.id.rawValue, measure: spec)
    }

    var safety: GoalSafetyGate.Assessment? {
        guard metric == .weight, template?.id != .weightMaintain, hasDate,
              let goal = buildGoal(weeklyGoalId: nil) else { return nil }
        return GoalSafetyGate.assess(goal: goal, bodyWeightKg: currentWeight ?? profileWeightKg)
    }

    func weeklyDraft(parentId: UUID) -> PeriodGoal? {
        guard let template else { return nil }
        if let weekly = template.id.weeklyMetric {
            // The goal itself is a weekly rhythm: its weekly goal is not optional.
            return PeriodGoal(metric: weekly, period: .week, target: target,
                              threshold: weekly.defaultThreshold == nil ? nil : threshold,
                              sportFilter: weekly == .workouts ? sportFilter : [],
                              habitKey: weekly == .habitDays ? habitKey : nil, habitWantsYes: habitWantsYes,
                              parentGoalId: parentId)
        }
        guard weeklyOn else { return nil }
        switch template.id {
        case .distanceTotal:
            return PeriodGoal(metric: .distance, period: .week, target: weeklyTarget, sportFilter: sportFilter,
                              parentGoalId: parentId, followsParent: true)
        case .timeTotal:
            return PeriodGoal(metric: .trainingMinutes, period: .week, target: weeklyTarget, sportFilter: sportFilter,
                              parentGoalId: parentId, followsParent: true)
        case .workoutsTotal:
            return PeriodGoal(metric: .workouts, period: .week, target: weeklyTarget, sportFilter: sportFilter,
                              parentGoalId: parentId, followsParent: true)
        case .stepsTotal:
            return PeriodGoal(metric: .stepDays, period: .week, target: weeklyTarget,
                              threshold: PeriodMetric.stepDays.defaultThreshold, parentGoalId: parentId)
        case .stepsAverage:
            return PeriodGoal(metric: .stepDays, period: .week, target: weeklyTarget, threshold: target,
                              parentGoalId: parentId)
        case .longest, .event:
            return PeriodGoal(metric: .distance, period: .week, target: weeklyTarget, sportFilter: sportFilter,
                              parentGoalId: parentId)
        case .weightLose, .weightMaintain:
            return weeklyChoice == .workouts
                ? PeriodGoal(metric: .workouts, period: .week, target: weeklyTarget, parentGoalId: parentId)
                : PeriodGoal(metric: .stepDays, period: .week, target: weeklyTarget,
                             threshold: PeriodMetric.stepDays.defaultThreshold, parentGoalId: parentId)
        case .weightGain, .leanMass:
            return PeriodGoal(metric: hasLiftingLog ? .workingSets : .workouts, period: .week, target: weeklyTarget,
                              parentGoalId: parentId)
        case .bodyFat, .waist:
            return PeriodGoal(metric: .workouts, period: .week, target: weeklyTarget, parentGoalId: parentId)
        case .vo2max, .restingHr, .sleepHeartRate:
            return PeriodGoal(metric: .zoneMinutes, period: .week, target: weeklyTarget, parentGoalId: parentId)
        case .sleepAverage:
            return PeriodGoal(metric: .sleepNights, period: .week, target: weeklyTarget,
                              threshold: max(5, target - 0.5), parentGoalId: parentId)
        case .hrvAverage, .recoveryAverage:
            return PeriodGoal(metric: .sleepNights, period: .week, target: weeklyTarget, threshold: 7,
                              parentGoalId: parentId)
        case .paceAverage:
            return PeriodGoal(metric: .workouts, period: .week, target: weeklyTarget, sportFilter: ["Running"],
                              parentGoalId: parentId)
        default:
            return nil
        }
    }

    // MARK: - Saving

    /// How a weekly amount moves in the stepper: sessions, minutes, sets, kilocalories or days.
    var perWeekStep: (step: Double, range: ClosedRange<Double>) {
        switch weeklyMetric {
        case .workouts?: return (1, 1...14)
        case .workingSets?: return (5, 5...300)
        case .zoneMinutes?: return (10, 30...1_200)
        case .activeEnergy?: return (100, 500...30_000)
        case .restDays?: return (1, 1...5)
        case .strengthMinutes?, .moderateMinutes?, .vigorousMinutes?:
            let metric = weeklyMetric ?? .strengthMinutes
            return (metric.step(for: .week), metric.range(for: .week))
        default: return (1, 1...7)
        }
    }

    /// An active goal that measures what this template would: the same metric over the same sports,
    /// and for a weekly rhythm the same weekly measure.
    @MainActor
    func sameMeasureGoal(_ template: GoalTemplate, goals: CoachGoalStore, periods: PeriodGoalStore) -> CoachGoal? {
        goals.activeGoals.first { goal in
            guard let measure = goal.measure, measure.metric == template.id.metric,
                  Set(measure.sportFilter) == Set(sportFilter) else { return false }
            guard let weekly = template.id.weeklyMetric else { return true }
            return measure.weeklyGoalId.flatMap { id in periods.goals.first { $0.id == id } }?
                .metric == weekly
        }
    }

    /// Commits the goal and its weekly goal as the setup's Create does: an equal weekly slot already tracked is
    /// linked instead of a second one beside it. Returns the new goal's id, or nil when nothing could be built.
    @MainActor
    func commit(goals: CoachGoalStore, periods: PeriodGoalStore, replacing: UUID?,
                acknowledgedRisk: CoachGoal.RiskAcknowledgement?) -> UUID? {
        let parentId = UUID()
        let today = StoreReader.localDayKey(now)
        var weekly = weeklyDraft(parentId: parentId)
        if let draft = weekly, case .duplicate(let existingId)? = periods.canAdd(draft) {
            if periods.goal(id: existingId)?.parentGoalId == nil {
                periods.link(existingId, to: parentId)
                weekly = periods.goal(id: existingId)
            } else {
                weekly = nil
            }
        } else if let draft = weekly, periods.canAdd(draft) == nil {
            periods.commit(draft, today: today)
        } else {
            weekly = nil
        }
        guard var goal = buildGoal(weeklyGoalId: weekly?.id) else { return nil }
        goal = CoachGoal(id: parentId, kind: goal.kind, title: goal.title, baseline: goal.baseline,
                         target: goal.target, targetDate: goal.targetDate, motivation: goal.motivation,
                         templateId: goal.templateId, measure: goal.measure)
        goals.commit(goal, replacing: replacing, acknowledgedRisk: acknowledgedRisk)
        return parentId
    }
}

/// Small shared helper (#R12): builds a pace acknowledgement from a raw reason, so the one-page editor
/// and the guided flow record it identically (a blank reason becomes an honest "No reason given").
enum CoachGoalRisk {
    static func acknowledgement(verdict: String, reason: String) -> CoachGoal.RiskAcknowledgement {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoachGoal.RiskAcknowledgement(verdict: verdict,
                                             reason: why.isEmpty ? "No reason given" : why,
                                             date: Date())
    }
}
