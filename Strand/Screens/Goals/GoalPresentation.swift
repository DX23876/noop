import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore

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
                                           symbol: "questionmark.circle", tone: .warning)
        case .building:       return .init(word: "Building evidence", wordText: String(localized: "Building evidence"),
                                           symbol: "hourglass", tone: .neutral)
        case .paused:         return .init(word: "Paused", wordText: String(localized: "Paused"),
                                           symbol: "pause.circle", tone: .neutral)
        }
    }

    /// The fill colour for a goal's progress: the goal's own colour, so done work always looks like
    /// done work (a filled day, a filled bar) and every goal keeps one colour across all surfaces. The
    /// verdict lives in the state word and symbol next to it. A period that can no longer be reached
    /// fills quieter; without data there is nothing to fill.
    static func trackTint(_ state: PeriodGoalState, identity: Color) -> Color {
        switch state {
        case .noData: return StrandPalette.textTertiary
        case .outOfReach, .protected: return identity.opacity(0.55)
        default: return identity
        }
    }

    /// Whether the state asks for attention (sorts "needs attention" first, feeds "+N need attention").
    static func needsAttention(_ state: PeriodGoalState) -> Bool {
        PeriodGoalMaintenance.needsAttention(state)
    }
}

/// The VoiceOver sentence for a goal row: the state's word joins the shared format.
extension GoalFormat {
    /// VoiceOver sentence for a goal row.
    static func accessibility(_ snapshot: PeriodGoalSnapshot) -> String {
        let style = GoalStatusStyle.of(snapshot.state)
        return "\(shortName(snapshot.goal)). \(style.wordText). \(progress(snapshot)). \(remainingLine(snapshot))."
    }
}

extension PeriodGoalSnapshot {
    var style: GoalStatusStyle { GoalStatusStyle.of(state) }
    var identityColor: Color {
        let apple = UserDefaults.standard.object(forKey: AppleInspiredColorsPrefs.enabledKey) as? Bool
            ?? AppleInspiredColorsPrefs.defaultEnabled
        return goalIdentityColor(goal.metric, appleColors: apple)
    }
    var trackTint: Color { GoalStatusStyle.trackTint(state, identity: identityColor) }

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
