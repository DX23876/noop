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

    static func of(_ state: PeriodGoalState) -> GoalStatusStyle { .init(GoalStatusWord.of(state)) }

    static func of(_ outcome: PeriodOutcome) -> GoalStatusStyle { .init(GoalStatusWord.of(outcome)) }

    /// The long-term goals' existing health, in the same vocabulary.
    static func of(_ health: GoalTrackingSnapshot.Health) -> GoalStatusStyle { .init(GoalStatusWord.of(health)) }

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

extension GoalStatusStyle {
    /// The shared state word (`GoalStatusWord`) in Apple's palette. In an extension, so the memberwise init stays.
    init(_ shared: GoalStatusWord) {
        word = LocalizedStringKey(shared.key)
        wordText = shared.text
        symbol = shared.symbol
        tone = StrandTone(shared.tone)
    }
}

extension StrandTone {
    init(_ tone: GoalTone) {
        switch tone {
        case .neutral: self = .neutral
        case .accent: self = .accent
        case .positive: self = .positive
        case .warning: self = .warning
        case .critical: self = .critical
        }
    }
}
