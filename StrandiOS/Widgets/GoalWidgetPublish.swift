#if os(iOS)
import Foundation
import WidgetKit
import StrandAnalytics
import StrandDesign

/// Publishes the goals for the goal widget, the lock-screen accessories and Siri, in the app's own words
/// and tones: the weekly and monthly goals, the long-term goals with a catalog reading, and today's daily
/// goals. Called on every goal tracking refresh; writes and reloads only when something the widget draws
/// changed.
@MainActor
enum GoalWidgetPublisher {
    static func publish(_ snapshots: [PeriodGoalSnapshot], daily: [GoalActionOccurrence] = [],
                        longTerm: [GoalTrackingSnapshot] = [], now: Date = Date()) {
        let appleColors = UserDefaults.standard.object(forKey: AppleInspiredColorsPrefs.enabledKey) as? Bool
            ?? AppleInspiredColorsPrefs.defaultEnabled
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
                         needsAttention: GoalStatusStyle.needsAttention(s.state),
                         glyph: glyph(s), colorKey: appleColors ? s.goal.metric.colorKey : "")
        }
        let longGoals = longTerm.filter { $0.goal.status == .active && $0.reading != nil }
            .compactMap { s in longTermGoal(s, appleColors: appleColors) }
        let week = ordered.first { $0.goal.period == .week }
        let daysLeft = week?.daysLeft ?? 0
        let weekLabel = daysLeft == 1 ? String(localized: "This week · last day")
                                      : String(localized: "This week · \(daysLeft) days left")
        let onCourse = ordered.filter { [.onTrack, .ahead, .achieved].contains($0.state) }.count
        // The same choice Today's goals card makes: up to three goals, the ones that need a look first,
        // the rows still free filled with long-term goals.
        let spot = GoalSpotlight.make(todayActions: daily, periodSnapshots: snapshots, longTerm: longTerm,
                                      pinnedLongTerm: GoalPrefs.pinnedLongTermIds, maxRows: 3,
                                      fillsWithLongTerm: true)
        let rings = spot.rings.map { o in
            GoalWidgetSnapshot.Daily(id: o.action.id.uuidString, name: o.action.title, symbol: o.ringSymbol,
                                     colorKey: appleColors ? o.colorKey : "", value: o.ringValueText,
                                     target: o.ringTargetText,
                                     fraction: o.isCompleted ? 1 : min(1, max(0, o.fraction ?? 0)),
                                     done: o.isCompleted)
        }
        let spotlightIds: [String] = spot.rows.map { row in
            switch row {
            case .period(let s, _): return s.id.uuidString
            case .longTerm(let s, _): return s.id.uuidString
            }
        }
        let snapshot = GoalWidgetSnapshot(goals: goals + longGoals, weekLabel: weekLabel,
                                          summary: spot.summary ?? String(localized: "\(onCourse) of \(ordered.count) on course"),
                                          updated: now, daily: rings, spotlightIds: spotlightIds,
                                          dailyTotal: spot.dailyTotal, dailyDone: spot.dailyDone,
                                          weekEnd: weekEnd(week))
        if snapshot.save() {
            WidgetCenter.shared.reloadTimelines(ofKind: GoalWidgetSnapshot.widgetKind)
        }
    }

    /// A long-term goal with a catalog reading, in the words of its page: "1,012,989" of "1,800,000".
    private static func longTermGoal(_ s: GoalTrackingSnapshot, appleColors: Bool) -> GoalWidgetSnapshot.Goal? {
        guard let content = LongTermGoalContent(s), let reading = s.reading else { return nil }
        let style = content.style
        let kindKey = "coach.goal.\(s.goal.kind.rawValue)"
        return .init(id: s.id.uuidString, name: s.displayTitle, title: s.displayTitle,
                     symbol: GoalCatalog.template(for: s.goal)?.icon ?? s.goal.kind.icon, period: "longTerm",
                     stateWord: style.wordText, stateSymbol: style.symbol, tone: tone(style.tone),
                     progress: content.heroValue, remaining: content.heroCaption ?? "",
                     headline: content.heroValue, fraction: reading.progress ?? 0, paceFraction: nil,
                     needsAttention: style.tone == .warning || style.tone == .critical,
                     glyph: glyph(reading), colorKey: appleColors ? kindKey : "")
    }

    /// A weekly or monthly goal's shape, the same one its row on Today draws.
    private static func glyph(_ s: PeriodGoalSnapshot) -> GoalWidgetSnapshot.Glyph {
        let r = s.result
        let pace = s.state == .achieved ? nil : r.paceFraction
        switch s.goal.metric.aggregation {
        case .count, .sum:
            return .init(kind: "track", fraction: r.fraction, paceFraction: pace)
        case .hitDays:
            guard s.goal.period == .week else { return .init(kind: "track", fraction: r.fraction, paceFraction: pace) }
            return .init(kind: "days", states: s.dayDots().map { dayState($0.state) })
        case .average:
            let values = s.dayValues.enumerated().map { $0.offset <= s.todayIndex ? $0.element : nil }
            return .init(kind: "columns", values: values, target: r.target, higherIsBetter: true)
        }
    }

    /// A long-term goal's shape, the same one `GoalShapeGlyph` draws on Today.
    private static func glyph(_ reading: GoalShapeReading) -> GoalWidgetSnapshot.Glyph? {
        switch reading {
        case .sum(let d):
            let r = d.reading
            return .init(kind: "track", fraction: min(1, max(0, r.fraction)),
                         paceFraction: r.target > 0 ? min(1, max(0, r.plannedByNow / r.target)) : nil)
        case .target(let d):
            return .init(kind: "way", fraction: d.progress,
                         marks: GoalShapeGlyph.marks(d.milestones, from: d.baseline, to: d.target))
        case .best(let d):
            return .init(kind: "track", fraction: min(1, max(0, d.reading.fraction ?? 0)))
        case .consistency(let d):
            guard !d.lastWeeks.isEmpty else { return nil }
            return .init(kind: "weeks", states: d.lastWeeks.map(\.rawValue))
        case .average(let d):
            return .init(kind: "columns", values: Array(d.days.suffix(14)), target: d.target,
                         higherIsBetter: d.higherIsBetter)
        case .maintain(let d):
            guard d.band > 0 else { return nil }
            let low = d.center - 2 * d.band, span = 4 * d.band
            func along(_ v: Double) -> Double { min(1, max(0, (v - low) / span)) }
            return .init(kind: "band", bandLow: along(d.center - d.band), bandHigh: along(d.center + d.band),
                         latest: d.reading.latest.map(along))
        }
    }

    private static func dayState(_ state: DayDotStrip.DayState) -> String {
        switch state {
        case .met: return "met"
        case .missed: return "missed"
        case .today: return "today"
        case .todayMet: return "todayMet"
        case .future: return "future"
        case .rest: return "rest"
        case .noData: return "noData"
        }
    }

    /// The start of the day after the week's last day, in the training week's calendar.
    private static func weekEnd(_ week: PeriodGoalSnapshot?) -> Date? {
        let calendar = TrainingPreferences.weekCalendar
        guard let last = week?.periodDays.last, let day = PeriodGoalTracker.date(last, calendar: calendar) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
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
