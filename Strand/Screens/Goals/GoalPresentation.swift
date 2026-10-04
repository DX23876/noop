import SwiftUI
import StrandDesign
import StrandAnalytics

/// One table for how a goal's state reads, used by every surface (Today, the overview, the detail,
/// widgets). A state is always a word AND a symbol; the colour only adds to them.
struct GoalStatusStyle {
    let word: LocalizedStringKey
    let wordText: String
    let symbol: String
    let tone: StrandTone

    var color: Color { tone.color }
    var foreground: Color { tone.foregroundColor }

    static func of(_ state: PeriodGoalState) -> GoalStatusStyle {
        switch state {
        case .achieved:   return .init(word: "Achieved", wordText: String(localized: "Achieved"),
                                       symbol: "checkmark.circle.fill", tone: .positive)
        case .ahead:      return .init(word: "Ahead", wordText: String(localized: "Ahead"),
                                       symbol: "arrow.up.right", tone: .positive)
        case .onTrack:    return .init(word: "On track", wordText: String(localized: "On track"),
                                       symbol: "circle.fill", tone: .positive)
        case .close:      return .init(word: "Close", wordText: String(localized: "Close"),
                                       symbol: "exclamationmark", tone: .warning)
        case .behind:     return .init(word: "Behind", wordText: String(localized: "Behind"),
                                       symbol: "arrow.down.right", tone: .critical)
        case .outOfReach: return .init(word: "Out of reach", wordText: String(localized: "Out of reach"),
                                       symbol: "minus.circle", tone: .neutral)
        case .protected:  return .init(word: "Protected", wordText: String(localized: "Protected"),
                                       symbol: "shield", tone: .accent)
        case .starting:   return .init(word: "Starting", wordText: String(localized: "Starting"),
                                       symbol: "hourglass", tone: .neutral)
        case .noData:     return .init(word: "No data", wordText: String(localized: "No data"),
                                       symbol: "questionmark", tone: .neutral)
        }
    }

    static func of(_ outcome: PeriodOutcome) -> GoalStatusStyle {
        switch outcome {
        case .achieved:  return of(PeriodGoalState.achieved)
        case .almost:    return .init(word: "Almost", wordText: String(localized: "Almost"),
                                      symbol: "circle.lefthalf.filled", tone: .positive)
        case .missed:    return .init(word: "Missed", wordText: String(localized: "Missed"),
                                      symbol: "circle", tone: .warning)
        case .protected: return of(PeriodGoalState.protected)
        case .noData:    return of(PeriodGoalState.noData)
        }
    }

    /// The long-term goals' existing health, in the same vocabulary.
    static func of(_ health: GoalTrackingSnapshot.Health) -> GoalStatusStyle {
        switch health {
        case .onTrack:        return of(PeriodGoalState.onTrack)
        case .attention:      return .init(word: "Needs attention", wordText: String(localized: "Needs attention"),
                                           symbol: "exclamationmark", tone: .warning)
        case .atRisk:         return .init(word: "At risk", wordText: String(localized: "At risk"),
                                           symbol: "arrow.down.right", tone: .critical)
        case .decisionNeeded: return .init(word: "Decision needed", wordText: String(localized: "Decision needed"),
                                           symbol: "questionmark.circle", tone: .critical)
        case .building:       return .init(word: "Building evidence", wordText: String(localized: "Building evidence"),
                                           symbol: "hourglass", tone: .neutral)
        case .paused:         return .init(word: "Paused", wordText: String(localized: "Paused"),
                                           symbol: "pause.circle", tone: .neutral)
        }
    }

    /// The fill colour for a pace track. "Starting" and "no data" fill neutrally: no verdict yet.
    static func trackTint(_ state: PeriodGoalState) -> Color {
        switch state {
        case .starting, .noData, .outOfReach: return StrandPalette.textSecondary
        default: return of(state).color
        }
    }

    /// Whether the state asks for attention (sorts "needs attention" first, feeds "+N need attention").
    static func needsAttention(_ state: PeriodGoalState) -> Bool {
        state == .close || state == .behind
    }
}

/// Numbers and sentences for period goals, in the wearer's units.
enum GoalFormat {

    static var distanceSystem: UnitSystem {
        let body = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        return UnitPrefs.resolveDistance(system: body,
                                         override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
    }

    /// A stored value (km for distance) in the unit shown.
    static func display(_ value: Double, _ metric: PeriodMetric) -> Double {
        metric == .distance && distanceSystem == .imperial ? UnitFormatter.kmToMiles(value) : value
    }

    /// A shown value back to the stored unit.
    static func stored(_ shown: Double, _ metric: PeriodMetric) -> Double {
        metric == .distance && distanceSystem == .imperial ? shown / UnitFormatter.milesPerKilometer : shown
    }

    /// The number alone: whole for counts and days, one decimal for km and hours.
    static func number(_ value: Double, _ metric: PeriodMetric) -> String {
        let shown = display(value, metric)
        switch metric {
        case .distance:
            return shown.formatted(.number.precision(.fractionLength(0...1)))
        case .sleepAverage:
            return shown.formatted(.number.precision(.fractionLength(1)))
        default:
            return Int(shown.rounded()).formatted()
        }
    }

    /// The unit word after a number, catalog-resolved.
    static func unit(_ metric: PeriodMetric) -> String {
        switch metric {
        case .workouts:        return String(localized: "workouts")
        case .trainingMinutes, .zoneMinutes: return String(localized: "min")
        case .distance:        return UnitFormatter.distanceUnit(distanceSystem)
        case .stepDays, .sleepNights, .restDays, .hydrationDays, .habitDays: return String(localized: "days")
        case .sleepAverage:    return String(localized: "h")
        case .workingSets:     return String(localized: "sets")
        case .activeEnergy:    return String(localized: "kcal")
        }
    }

    static func amount(_ value: Double, _ metric: PeriodMetric) -> String {
        "\(number(value, metric)) \(unit(metric))"
    }

    /// "2/4", or "7.2 h" for an average.
    static func progress(_ snapshot: PeriodGoalSnapshot) -> String {
        let goal = snapshot.goal
        if goal.metric.aggregation == .average {
            return amount(snapshot.result.current, goal.metric)
        }
        return "\(number(snapshot.result.current, goal.metric))/\(number(snapshot.result.target, goal.metric))"
    }

    /// The goal's name as the wearer reads it: "4 workouts a week", "60 km a month", "5 nights of 7 h".
    static func title(_ goal: PeriodGoal) -> String {
        let perPeriod = goal.period == .week ? String(localized: "a week") : String(localized: "a month")
        let target = number(goal.target, goal.metric)
        switch goal.metric {
        case .stepDays:
            let steps = Int((goal.threshold ?? 8_000).rounded()).formatted()
            return String(localized: "\(target) days of \(steps) steps \(perPeriod)")
        case .sleepNights:
            let hours = (goal.threshold ?? 7).formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "\(target) nights of \(hours) h \(perPeriod)")
        case .sleepAverage:
            return String(localized: "\(target) h average sleep \(perPeriod)")
        case .habitDays:
            let habit = goal.habitKey.map(JournalLabel.display) ?? goal.metric.label.localizedCatalogValue
            return goal.habitWantsYes
                ? String(localized: "\(habit) on \(target) days \(perPeriod)")
                : String(localized: "\(target) days without \(habit) \(perPeriod)")
        case .workouts where !goal.sportFilter.isEmpty:
            return String(localized: "\(target) × \(goal.sportFilter.joined(separator: ", ")) \(perPeriod)")
        default:
            return "\(target) \(unit(goal.metric)) \(perPeriod)"
        }
    }

    /// Short name for rows: the metric with its sport or habit.
    static func shortName(_ goal: PeriodGoal) -> String {
        switch goal.metric {
        case .workouts where !goal.sportFilter.isEmpty: return goal.sportFilter.joined(separator: ", ")
        case .habitDays: return goal.habitKey.map(JournalLabel.display) ?? goal.metric.label.localizedCatalogValue
        case .stepDays:
            return String(localized: "\(Int((goal.threshold ?? 8_000).rounded()).formatted()) steps")
        case .sleepNights:
            let hours = (goal.threshold ?? 7).formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "Nights of \(hours) h")
        default: return goal.metric.label.localizedCatalogValue
        }
    }

    /// The line under a goal: what is left, in numbers before words (design §14).
    static func remainingLine(_ snapshot: PeriodGoalSnapshot) -> String {
        let goal = snapshot.goal
        let r = snapshot.result
        let left = snapshot.daysLeft
        switch r.state {
        case .achieved:
            let over = r.current - r.target
            if goal.metric.aggregation != .average, over >= goal.metric.step(for: goal.period) - 1e-9 {
                return String(localized: "\(number(over, goal.metric)) over target")
            }
            return String(localized: "Done for this \(periodWord(goal.period))")
        case .protected:
            return String(localized: "Protected, this \(periodWord(goal.period)) does not count")
        case .noData:
            return String(localized: "Too few days with data to judge")
        case .outOfReach:
            // The state already says "out of reach"; the line says how much was missing.
            return String(localized: "\(amount(r.remaining, goal.metric)) short, too few days left")
        default:
            break
        }
        if goal.metric.aggregation == .average {
            if let needed = r.requiredPerDay, r.remainingDays > 0, r.state != .onTrack, r.state != .ahead {
                return String(localized: "Needs \(number(needed, goal.metric)) h a night from here")
            }
            return String(localized: "Average so far · target \(amount(r.target, goal.metric))")
        }
        let remaining = amount(r.remaining, goal.metric)
        if r.isProrated && snapshot.history.isEmpty {
            return String(localized: "First \(periodWord(goal.period)), pro-rated: \(remaining) to go")
        }
        return left == 1
            ? String(localized: "\(remaining) to go · last day")
            : String(localized: "\(remaining) to go · \(left) days left")
    }

    static func periodWord(_ period: PeriodGoal.Period) -> String {
        period == .week ? String(localized: "week") : String(localized: "month")
    }

    /// "6 to 12 October", the range of a period.
    static func range(_ days: [String]) -> String {
        guard let first = days.first, let last = days.last,
              let a = PeriodGoalTracker.date(first, calendar: .autoupdatingCurrent),
              let b = PeriodGoalTracker.date(last, calendar: .autoupdatingCurrent) else { return "" }
        let style = Date.FormatStyle.dateTime.day().month(.wide)
        return String(localized: "\(a.formatted(style)) to \(b.formatted(style))")
    }

    /// Weekday initial for a day key ("M").
    static func weekdayInitial(_ day: String) -> String {
        guard let weekday = PeriodCalendar.weekday(day) else { return "" }
        let symbols = Calendar.autoupdatingCurrent.veryShortStandaloneWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }

    /// VoiceOver sentence for a goal row.
    static func accessibility(_ snapshot: PeriodGoalSnapshot) -> String {
        let style = GoalStatusStyle.of(snapshot.state)
        return "\(shortName(snapshot.goal)). \(style.wordText). \(progress(snapshot)). \(remainingLine(snapshot))."
    }
}

/// Journal keys are canonical strings; their display name may have been renamed in the catalog.
enum JournalLabel {
    static func display(_ canonical: String) -> String {
        guard let data = UserDefaults.standard.data(forKey: JournalCatalogBackupKeys.items),
              let items = try? JSONDecoder().decode([JournalCatalogItem].self, from: data),
              let item = items.first(where: { $0.canonical == canonical }) else { return canonical }
        return item.displayName ?? item.canonical
    }
}

extension PeriodGoalSnapshot {
    var style: GoalStatusStyle { GoalStatusStyle.of(state) }
    var trackTint: Color { GoalStatusStyle.trackTint(state) }

    /// Segments for small count goals; continuous otherwise.
    var trackSegments: Int? {
        guard goal.metric.aggregation == .count || goal.metric.aggregation == .hitDays else { return nil }
        let t = Int(result.target.rounded())
        return (2...10).contains(t) ? t : nil
    }

    /// The day strip for count and hit-day goals.
    func dayDots(diameter: CGFloat = 14, withSymbols: Bool = false) -> [DayDotStrip.Day] {
        periodDays.enumerated().map { index, day in
            let value = dayValues[index]
            let isToday = index == todayIndex
            let met = (value ?? 0) > 0
            let state: DayDotStrip.DayState
            if isToday { state = met ? .todayMet : .today }
            else if index > todayIndex { state = restDays.contains(day) ? .rest : .future }
            else if value == nil { state = .noData }
            else if met { state = .met }
            else { state = restDays.contains(day) ? .rest : .missed }
            let symbol: String? = withSymbols && met && goal.metric.isWorkoutBased
                ? counted.first(where: { $0.day == day }).map { sportSymbol($0.title) } : nil
            return .init(id: day, state: state,
                         label: goal.period == .week ? GoalFormat.weekdayInitial(day) : "", symbol: symbol)
        }
    }
}

/// The identity colour of a metric (its icon), from the same Apple-inspired table as the long-term kinds.
func goalIdentityColor(_ metric: PeriodMetric, appleColors: Bool) -> Color {
    appleColors ? CoachIconColors.color(for: metric.colorKey) : StrandPalette.accent
}
