#if os(iOS)
import Foundation
import WidgetKit
import StrandAnalytics
import StrandDesign

/// Publishes the weekly and monthly goals for the goal widget, the lock-screen accessories and Siri, in
/// the app's own words and tones. Called on every goal tracking refresh; writes and reloads only when
/// something the widget draws changed.
@MainActor
enum GoalWidgetPublisher {
    static func publish(_ snapshots: [PeriodGoalSnapshot], now: Date = Date()) {
        let open = snapshots.filter { $0.goal.status == .active }
        let ordered = open.filter { $0.goal.period == .week } + open.filter { $0.goal.period == .month }
        let goals = ordered.map { s -> GoalWidgetSnapshot.Goal in
            let style = s.style
            return .init(id: s.id.uuidString, name: GoalFormat.shortName(s.goal), title: GoalFormat.title(s.goal),
                         symbol: s.goal.metric.icon, period: s.goal.period.rawValue,
                         stateWord: style.wordText, stateSymbol: style.symbol, tone: tone(style.tone),
                         progress: GoalFormat.progress(s), remaining: GoalFormat.remainingLine(s),
                         headline: headline(s), fraction: s.result.fraction,
                         paceFraction: s.state == .achieved ? nil : s.result.paceFraction,
                         needsAttention: GoalStatusStyle.needsAttention(s.state))
        }
        let week = ordered.first { $0.goal.period == .week }
        let daysLeft = week?.daysLeft ?? 0
        let weekLabel = daysLeft == 1 ? String(localized: "This week · last day")
                                      : String(localized: "This week · \(daysLeft) days left")
        let onCourse = ordered.filter { [.onTrack, .ahead, .achieved].contains($0.state) }.count
        let snapshot = GoalWidgetSnapshot(goals: goals, weekLabel: weekLabel,
                                          summary: String(localized: "\(onCourse) of \(ordered.count) on course"),
                                          updated: now)
        if snapshot.save() {
            WidgetCenter.shared.reloadTimelines(ofKind: GoalWidgetSnapshot.widgetKind)
        }
    }

    /// The large line on the small widget: what is left, or the state when nothing is.
    private static func headline(_ s: PeriodGoalSnapshot) -> String {
        switch s.state {
        case .achieved, .protected, .noData, .outOfReach: return s.style.wordText
        default:
            if s.goal.metric.aggregation == .average { return GoalFormat.amount(s.result.current, s.goal.metric) }
            return String(localized: "\(GoalFormat.number(s.result.remaining, s.goal.metric)) to go")
        }
    }

    private static func tone(_ tone: StrandTone) -> String {
        switch tone {
        case .positive: return "positive"
        case .warning:  return "warning"
        case .critical: return "critical"
        case .accent:   return "accent"
        case .neutral:  return "neutral"
        }
    }
}
#endif
