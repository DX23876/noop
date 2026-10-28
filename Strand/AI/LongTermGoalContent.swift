import Foundation
import StrandAnalytics
import StrandCore

/// A tone a goal's state or figure is drawn in; each platform maps it to its own palette.
enum GoalTone: String, Encodable { case neutral, accent, positive, warning, critical }

/// How a goal's state reads: always a word AND a symbol; the tone only adds to them. Shared by Apple's
/// `GoalStatusStyle` and the Android core (parity plan 2.3). `key` is the catalog key, `text` its translation.
struct GoalStatusWord {
    let key: String
    let text: String
    let symbol: String
    let tone: GoalTone

    static func of(_ state: PeriodGoalState) -> GoalStatusWord {
        switch state {
        case .achieved:   return .init(key: "Achieved", text: String(localized: "Achieved"),
                                       symbol: "checkmark.circle.fill", tone: .positive)
        case .ahead:      return .init(key: "Ahead", text: String(localized: "Ahead"),
                                       symbol: "arrow.up.right", tone: .positive)
        case .onTrack:    return .init(key: "On track", text: String(localized: "On track"),
                                       symbol: "circle.fill", tone: .positive)
        case .close:      return .init(key: "Close", text: String(localized: "Close"),
                                       symbol: "exclamationmark", tone: .warning)
        case .behind:     return .init(key: "Behind", text: String(localized: "Behind"),
                                       symbol: "arrow.down.right", tone: .critical)
        case .outOfReach: return .init(key: "Out of reach", text: String(localized: "Out of reach"),
                                       symbol: "minus.circle", tone: .neutral)
        case .protected:  return .init(key: "Protected", text: String(localized: "Protected"),
                                       symbol: "shield", tone: .accent)
        case .starting:   return .init(key: "Starting", text: String(localized: "Starting"),
                                       symbol: "hourglass", tone: .neutral)
        case .noData:     return .init(key: "No data", text: String(localized: "No data"),
                                       symbol: "questionmark", tone: .neutral)
        }
    }

    static func of(_ outcome: PeriodOutcome) -> GoalStatusWord {
        switch outcome {
        case .achieved:  return of(PeriodGoalState.achieved)
        case .almost:    return .init(key: "Almost", text: String(localized: "Almost"),
                                      symbol: "circle.lefthalf.filled", tone: .positive)
        case .missed:    return .init(key: "Missed", text: String(localized: "Missed"),
                                      symbol: "circle", tone: .warning)
        case .protected: return of(PeriodGoalState.protected)
        case .noData:    return of(PeriodGoalState.noData)
        }
    }

    /// The long-term goals' existing health, in the same vocabulary.
    static func of(_ health: GoalTrackingSnapshot.Health) -> GoalStatusWord {
        switch health {
        case .onTrack:        return of(PeriodGoalState.onTrack)
        case .attention:      return .init(key: "Needs attention", text: String(localized: "Needs attention"),
                                           symbol: "exclamationmark", tone: .warning)
        case .atRisk:         return .init(key: "At risk", text: String(localized: "At risk"),
                                           symbol: "arrow.down.right", tone: .critical)
        case .decisionNeeded: return .init(key: "Decision needed", text: String(localized: "Decision needed"),
                                           symbol: "questionmark.circle", tone: .warning)
        case .building:       return .init(key: "Building evidence", text: String(localized: "Building evidence"),
                                           symbol: "hourglass", tone: .neutral)
        case .paused:         return .init(key: "Paused", text: String(localized: "Paused"),
                                           symbol: "pause.circle", tone: .neutral)
        }
    }
}

/// Values of a catalog goal in the reader's format: kilometres, hours, kilos, a night's sleep. Shared with the
/// Android core (parity plan 2.3) with the long-term goal page below.
enum LongTermFormat {

    static func value(_ value: Double, _ metric: LongTermMetric) -> String {
        switch metric {
        case .distanceTotal, .longestDistance:
            let digits = value < 100 ? 1 : 0
            return String(localized: "\(value.formatted(.number.precision(.fractionLength(0...digits)))) km")
        case .minutesTotal:
            return String(localized: "\((value / 60).formatted(.number.precision(.fractionLength(0)))) h")
        case .workoutsTotal:
            return Int(value.rounded()).formatted()
        case .stepsTotal, .stepsAverage:
            return Int(value.rounded()).formatted()
        case .weight, .leanMass:
            return String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) kg")
        case .bodyFat:
            return String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) %")
        case .waist:
            return String(localized: "\(value.formatted(.number.precision(.fractionLength(0...1)))) cm")
        case .sleepAverage:
            return hoursAndMinutes(value)
        case .hrvAverage:
            return String(localized: "\(Int(value.rounded())) ms")
        case .recoveryAverage, .sleepConsistency:
            return String(localized: "\(Int(value.rounded())) %")
        case .vo2max:
            return value.formatted(.number.precision(.fractionLength(1)))
        case .restingHr, .sleepHeartRate:
            return String(localized: "\(Int(value.rounded())) bpm")
        case .paceAverage:
            let seconds = Int(value.rounded())
            return String(localized: "\(seconds / 60):\(String(format: "%02d", seconds % 60)) /km")
        case .weeklyAdherence:
            return "\(Int((value * 100).rounded())) %"
        }
    }

    /// A change, signed: "+22 min", "−0.6 kg".
    static func signed(_ value: Double, _ metric: LongTermMetric) -> String {
        let text = metric == .sleepAverage ? minutesText(abs(value) * 60) : self.value(abs(value), metric)
        if abs(value) < 1e-9 { return text }
        return (value > 0 ? "+" : "−") + text
    }

    static func hoursAndMinutes(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        if total % 60 == 0 { return String(localized: "\(total / 60) h") }
        return String(localized: "\(total / 60) h \(total % 60) min")
    }

    static func minutesText(_ minutes: Double) -> String {
        String(localized: "\(Int(minutes.rounded())) min")
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "in about 3 weeks", "in about 5 days", "this week".
    static func inAbout(days: Double) -> String {
        if days < 1 { return String(localized: "today") }
        if days < 14 { return String(localized: "in about \(Int(days.rounded())) days") }
        return String(localized: "in about \(Int((days / 7).rounded())) weeks")
    }

    /// A weekly amount in its own unit: "10× / week", "150 min / week", "5 nights / week".
    static func perWeek(_ value: Double, _ metric: PeriodMetric) -> String {
        let n = number(value)
        switch metric {
        case .workouts: return String(localized: "\(n)× / week")
        case .trainingMinutes, .zoneMinutes, .strengthMinutes, .moderateMinutes, .vigorousMinutes:
            return String(localized: "\(n) min / week")
        case .distance: return String(localized: "\(n) km / week")
        case .workingSets: return String(localized: "\(n) sets / week")
        case .activeEnergy: return String(localized: "\(n) kcal / week")
        case .sleepNights: return String(localized: "\(n) nights / week")
        case .restDays: return String(localized: "\(n) rest days / week")
        case .stepDays, .hydrationDays, .habitDays: return String(localized: "\(n) days / week")
        case .sleepAverage: return hoursAndMinutes(value)
        }
    }

    /// What one day has to reach for a day-counting weekly goal, nil for the others.
    static func dayBar(_ metric: PeriodMetric, threshold: Double?) -> String? {
        switch metric {
        case .stepDays:
            let steps = Int((threshold ?? metric.defaultThreshold ?? 0).rounded())
            return String(localized: "from \(steps.formatted()) steps a day")
        case .sleepNights:
            return String(localized: "from \(hoursAndMinutes(threshold ?? metric.defaultThreshold ?? 7)) a night")
        default:
            return nil
        }
    }

    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.autoupdatingCurrent.standaloneWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }
}

/// Everything a catalog goal's hero, band and insights show, worked out once from its snapshot. Apple maps the plain
/// types to its design components; Android receives them from the core.
struct LongTermGoalContent {

    /// One figure along the hero's bottom; `fraction` (0…1) draws a small bar under it.
    struct Stat: Identifiable {
        let id: Int
        let label: String
        let value: String
        var fraction: Double?
    }

    enum PointState: String { case reached, next, open }

    struct Point: Identifiable {
        let id: Int
        let label: String
        let state: PointState
    }

    enum WeekState: String { case kept, almost, missed, protected, noData, running }

    struct Week: Identifiable {
        let id: Int
        let label: String
        let state: WeekState
    }

    enum Band {
        /// The visible window, and every waypoint for the full list a tap opens.
        case milestones([Point], moreBefore: Bool, moreAfter: Bool, all: [Point])
        case weeks([Week])
        case columns([Double?], target: Double, higherIsBetter: Bool)
    }

    struct Insight: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let value: String
        let caption: String?
        let tone: GoalTone?
    }

    let title: String
    let status: GoalStatusWord
    let heroValue: String
    let heroCaption: String?
    let figures: [Stat]
    let bandTitle: String
    let band: Band?
    let insights: [Insight]

    /// The style for a snapshot: the catalog reading's state where there is one, else the kind's health.
    static func style(_ snapshot: GoalTrackingSnapshot) -> GoalStatusWord {
        if let state = snapshot.reading?.state { return GoalStatusWord.of(state) }
        if snapshot.reading != nil {
            return GoalStatusWord(key: "Running", text: String(localized: "Running"), symbol: "circle.dashed", tone: .neutral)
        }
        return GoalStatusWord.of(snapshot.health)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init?(_ snapshot: GoalTrackingSnapshot) {
        guard let reading = snapshot.reading else { return nil }
        title = snapshot.displayTitle
        let style = Self.style(snapshot)
        status = style
        let toneOfState = style.tone

        switch reading {
        case .sum(let d):
            let r = d.reading
            heroValue = LongTermFormat.value(r.total, d.metric)
            heroCaption = String(localized: "of \(LongTermFormat.value(r.target, d.metric))")
            figures = [
                .init(id: 0, label: String(localized: "Target"), value: LongTermFormat.value(r.target, d.metric)),
                .init(id: 1, label: String(localized: "Progress"),
                      value: "\(Int((min(1, r.fraction) * 100).rounded())) %", fraction: min(1, r.fraction)),
                .init(id: 2, label: String(localized: "Estimated"),
                      value: r.projectedFinish.map(LongTermFormat.shortDate) ?? "–"),
            ]
            bandTitle = Self.milestoneTitle(d.milestones)
            band = Self.milestoneBand(d.milestones, metric: d.metric)
            var items: [Insight] = []
            items.append(.init(id: 0, icon: "speedometer", title: String(localized: "Current pace"),
                               value: r.recentWeeklyAverage.map { String(localized: "\(LongTermFormat.value($0, d.metric))/week") } ?? "–",
                               caption: r.recentWeeklyAverage == nil ? String(localized: "After four weeks of data")
                                                                      : style.text,
                               tone: r.recentWeeklyAverage == nil ? nil : toneOfState))
            if let next = d.milestones?.next {
                let caption = r.recentWeeklyAverage.flatMap { avg -> String? in
                    guard avg > 0 else { return nil }
                    return LongTermFormat.inAbout(days: (next - r.total) / avg * 7)
                }
                items.append(.init(id: 1, icon: "flag", title: String(localized: "Next milestone"),
                                   value: LongTermFormat.value(next, d.metric), caption: caption, tone: nil))
            }
            if let suggested = r.suggestedWeeklyTarget {
                items.append(.init(id: 2, icon: "calendar", title: String(localized: "Needed per week"),
                                   value: LongTermFormat.value(suggested, d.metric),
                                   caption: r.catchUpExceedsCap ? String(localized: "Getting tight by the end date")
                                                                : String(localized: "\(Int(r.weeksLeft)) weeks left"),
                                   tone: nil))
            }
            insights = items

        case .target(let d):
            heroValue = LongTermFormat.value(d.current, d.metric)
            // VO2max has no short unit to put on every figure; the caption names it once.
            // A single measurement carries its date, so a reading from last week is not passed off as today's.
            heroCaption = d.metric == .vo2max
                ? String(localized: "ml/kg/min, target \(LongTermFormat.value(d.target, d.metric))")
                : d.currentDate.map {
                    String(localized: "measured \(LongTermFormat.shortDate($0)), target \(LongTermFormat.value(d.target, d.metric))")
                } ?? String(localized: "target \(LongTermFormat.value(d.target, d.metric))")
            let next = d.milestones?.next
            figures = [
                .init(id: 0, label: String(localized: "Start"), value: LongTermFormat.value(d.baseline, d.metric)),
                .init(id: 1, label: String(localized: "Progress"),
                      value: "\(Int((d.progress * 100).rounded())) %", fraction: d.progress),
                .init(id: 2, label: String(localized: "Next mark"),
                      value: next.map { mark in
                          d.nextMarkDate.map { "\(LongTermFormat.value(mark, d.metric)) · \(LongTermFormat.shortDate($0))" }
                              ?? LongTermFormat.value(mark, d.metric)
                      } ?? "–"),
            ]
            bandTitle = Self.milestoneTitle(d.milestones)
            band = Self.milestoneBand(d.milestones, metric: d.metric)
            insights = [
                .init(id: 0, icon: "speedometer", title: String(localized: "Pace"),
                      value: d.ratePerWeek.map { String(localized: "\(LongTermFormat.signed($0, d.metric))/week") } ?? "–",
                      caption: d.ratePerWeek == nil ? String(localized: "After two weeks of readings") : style.text,
                      tone: d.ratePerWeek == nil ? nil : toneOfState),
                .init(id: 1, icon: "arrow.left.and.right", title: String(localized: "Since the start"),
                      value: LongTermFormat.signed(d.current - d.baseline, d.metric),
                      caption: String(localized: "from \(LongTermFormat.value(d.baseline, d.metric))"), tone: nil),
                .init(id: 2, icon: "calendar", title: String(localized: "Target reached"),
                      value: d.arrivalDate.map(LongTermFormat.shortDate) ?? "–",
                      caption: d.arrivalDate == nil ? String(localized: "More than a year at this pace, or no trend yet")
                                                    : String(localized: "at the current pace"),
                      tone: nil),
            ]

        case .best(let d):
            let r = d.reading
            let target = snapshot.goal.target ?? 0
            heroValue = r.best.map { LongTermFormat.value($0, .longestDistance) } ?? "–"
            heroCaption = String(localized: "best since the start")
            let third: Stat
            if let date = snapshot.goal.targetDate {
                let days = Calendar.autoupdatingCurrent.dateComponents([.day], from: Date(), to: date).day ?? 0
                let isRace = snapshot.goal.templateId == GoalTemplateID.event.rawValue
                third = .init(id: 2, label: isRace ? String(localized: "Race day") : String(localized: "By"),
                              value: days >= 0 ? LongTermFormat.inAbout(days: Double(days)) : LongTermFormat.shortDate(date))
            } else {
                third = .init(id: 2, label: String(localized: "Last best"),
                              value: r.daysSinceBest.map { $0 == 0 ? String(localized: "today")
                                  : String(localized: "\($0) days ago") } ?? "–")
            }
            figures = [
                .init(id: 0, label: String(localized: "Target"), value: LongTermFormat.value(target, .longestDistance)),
                .init(id: 1, label: String(localized: "Progress"),
                      value: r.fraction.map { "\(Int((min(1, $0) * 100).rounded())) %" } ?? "–",
                      fraction: r.fraction.map { min(1, $0) }),
                third,
            ]
            bandTitle = Self.milestoneTitle(d.milestones)
            band = Self.milestoneBand(d.milestones, metric: .longestDistance)
            insights = [
                .init(id: 0, icon: "speedometer", title: String(localized: "Per week"),
                      value: d.recentWeeklyDistance.map { String(localized: "\(LongTermFormat.value($0, .distanceTotal))/week") } ?? "–",
                      caption: String(localized: "last four weeks"), tone: r.state.map { _ in toneOfState }),
                .init(id: 1, icon: "arrow.up.right", title: String(localized: "Longest lately"),
                      value: r.recentBest.map { LongTermFormat.value($0, .longestDistance) } ?? "–",
                      caption: String(localized: "last four weeks"), tone: nil),
                .init(id: 2, icon: "clock.arrow.circlepath", title: String(localized: "Earlier best"),
                      value: r.earlierBest.map { LongTermFormat.value($0, .longestDistance) } ?? "–",
                      caption: String(localized: "before this goal"), tone: nil),
            ]

        case .consistency(let d):
            let r = d.reading
            heroValue = LongTermFormat.perWeek(d.weeklyTarget, d.weeklyMetric)
            heroCaption = LongTermFormat.dayBar(d.weeklyMetric, threshold: d.weeklyThreshold)
            figures = [
                .init(id: 0, label: String(localized: "Consistency"),
                      value: r.share.map { "\(Int(($0 * 100).rounded())) %" } ?? "–"),
                .init(id: 1, label: String(localized: "This week"),
                      value: "\(LongTermFormat.number(d.thisWeek)) / \(LongTermFormat.number(d.weeklyTarget))",
                      fraction: d.weeklyTarget > 0 ? min(1, d.thisWeek / d.weeklyTarget) : nil),
                .init(id: 2, label: String(localized: "Current streak"),
                      value: String(localized: "\(r.currentStreak) weeks")),
            ]
            bandTitle = String(localized: "Last 8 weeks")
            band = .weeks(zip(d.lastWeeks, d.lastWeekStarts).enumerated().map { index, pair in
                .init(id: index, label: Self.weekLabel(pair.1), state: Self.weekState(pair.0))
            })
            var items: [Insight] = []
            if let avg = d.averagePerWeek {
                let delta = d.previousAveragePerWeek.map { avg - $0 }
                items.append(.init(id: 0, icon: "chart.bar", title: String(localized: "Average per week"),
                                   value: LongTermFormat.number(avg),
                                   caption: delta.map { String(localized: "\($0 >= 0 ? "+" : "−")\(LongTermFormat.number(abs($0))) vs before") },
                                   tone: toneOfState))
            }
            if let weekday = d.strongestWeekday, let share = d.strongestWeekdayShare {
                items.append(.init(id: 1, icon: "calendar", title: String(localized: "Best day"),
                                   value: LongTermFormat.weekdayName(weekday),
                                   caption: String(localized: "\(Int((share * 100).rounded())) % of sessions"), tone: nil))
            }
            let missed = d.lastWeeks.filter { $0 == .missed }.count
            items.append(.init(id: 2, icon: "minus.circle", title: String(localized: "Missed weeks"),
                               value: d.lastWeeks.isEmpty ? "–" : String(localized: "\(missed) of \(d.lastWeeks.count)"),
                               caption: r.share.map { String(localized: "\(Int(($0 * 100).rounded())) % kept") }, tone: nil))
            insights = items

        case .maintain(let d):
            let r = d.reading
            heroValue = r.latest.map { LongTermFormat.value($0, d.metric) } ?? "–"
            heroCaption = String(localized: "\(LongTermFormat.value(d.center, d.metric)) ± \(LongTermFormat.value(d.band, d.metric))")
            figures = [
                .init(id: 0, label: String(localized: "Band"),
                      value: String(localized: "± \(LongTermFormat.value(d.band, d.metric))")),
                .init(id: 1, label: String(localized: "In the band"),
                      value: r.inBandShare.map { "\(Int(($0 * 100).rounded())) %" } ?? "–",
                      fraction: r.inBandShare),
                .init(id: 2, label: String(localized: "From the middle"),
                      value: r.deviation.map { LongTermFormat.signed($0, d.metric) } ?? "–"),
            ]
            bandTitle = ""
            band = nil
            insights = [
                .init(id: 0, icon: "equal.circle", title: String(localized: "In the band"),
                      value: r.inBandShare.map { "\(Int(($0 * 100).rounded())) %" } ?? "–",
                      caption: String(localized: "of readings, last four weeks"), tone: r.inBandShare == nil ? nil : toneOfState),
                .init(id: 1, icon: "arrow.up.and.down", title: String(localized: "Swing"),
                      value: r.spread.map { LongTermFormat.value($0, d.metric) } ?? "–",
                      caption: String(localized: "highest to lowest"), tone: nil),
                .init(id: 2, icon: "scalemass", title: String(localized: "Weigh-ins"),
                      value: "\(r.readings)", caption: String(localized: "last four weeks"), tone: nil),
            ]

        case .average(let d):
            let r = d.reading
            // A pace goal reads runs, not days: its band is one column per run.
            let isPace = d.metric == .paceAverage
            let meanText = r.mean.map { LongTermFormat.value($0, d.metric) } ?? "–"
            heroValue = meanText
            heroCaption = isPace && r.mean == nil && r.values > 0
                ? String(localized: "average from two runs of 3 km") : String(localized: "28-day average")
            figures = [
                .init(id: 0, label: String(localized: "Target"), value: LongTermFormat.value(d.target, d.metric)),
                .init(id: 1, label: String(localized: "Trend"),
                      value: r.trendPerMonth.map { String(localized: "\(LongTermFormat.signed($0, d.metric))/month") } ?? "–"),
                .init(id: 2, label: String(localized: "At target"),
                      value: isPace ? String(localized: "\(r.atTarget) / \(r.values) runs")
                                    : String(localized: "\(r.atTarget) / \(r.values) days")),
            ]
            bandTitle = isPace ? String(localized: "Runs, last 28 days") : String(localized: "28-day trend")
            band = .columns(d.days, target: d.target, higherIsBetter: d.higherIsBetter)
            insights = [
                .init(id: 0, icon: "chart.bar", title: String(localized: "Current average"),
                      value: meanText,
                      caption: r.trendPerMonth.map { String(localized: "\(LongTermFormat.signed($0, d.metric))/month") },
                      tone: r.mean == nil ? nil : toneOfState),
                .init(id: 1, icon: "target", title: String(localized: "Gap to target"),
                      value: r.gap.map { $0 < 1e-9 ? String(localized: "None") : LongTermFormat.signed($0, d.metric)
                          .replacingOccurrences(of: "+", with: "") } ?? "–",
                      caption: String(localized: "to reach \(LongTermFormat.value(d.target, d.metric))"), tone: nil),
                .init(id: 2, icon: "star", title: isPace ? String(localized: "Fastest run") : String(localized: "Best week"),
                      value: d.bestWeekMean.map { LongTermFormat.value($0, d.metric) } ?? "–",
                      caption: String(localized: "in the last four weeks"), tone: nil),
            ]
        }
    }

    /// "Milestones · 3 of 10": the band shows five at a time, so the count says how far the whole route is.
    private static func milestoneTitle(_ window: LongTermGoalMath.MilestoneWindow?) -> String {
        guard let window, window.values.count > window.visible.count else { return String(localized: "Milestones") }
        return String(localized: "Milestones · \(window.reachedCount) of \(window.values.count)")
    }

    private static func milestoneBand(_ window: LongTermGoalMath.MilestoneWindow?, metric: LongTermMetric) -> Band? {
        guard let window, !window.values.isEmpty else { return nil }
        let all = window.values.indices.map { index in
            Point(id: index, label: LongTermFormat.value(window.values[index], metric),
                                 state: index < window.reachedCount ? .reached
                                     : index == window.reachedCount ? .next : .open)
        }
        return .milestones(Array(all[window.visible]), moreBefore: window.visible.lowerBound > 0,
                           moreAfter: window.visible.upperBound < window.values.count, all: all)
    }

    private static func weekState(_ outcome: PeriodOutcome) -> WeekState {
        switch outcome {
        case .achieved: return .kept
        case .almost: return .almost
        case .missed: return .missed
        case .protected: return .protected
        case .noData: return .noData
        }
    }

    /// "W41": the calendar week the period starts in.
    private static func weekLabel(_ dayKey: String) -> String {
        guard let date = PeriodGoalTracker.date(dayKey, calendar: TrainingPreferences.weekCalendar) else { return "" }
        let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: date)
        return String(localized: "W\(week)")
    }
}

extension LongTermFormat {
    /// The step "Aim higher" moves a reached goal's target by.
    static func raiseStep(_ metric: LongTermMetric, _ value: Double) -> Double {
        switch metric {
        case .distanceTotal: return value >= 200 ? 50 : 10
        case .longestDistance, .weight: return 0.5
        case .sleepAverage: return 0.25
        default: return 1
        }
    }

    /// A count or a rate as a person says it: "3", "2.5".
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

extension GoalTrackingSnapshot {
    /// The goal's own title, or its kind when the user left the title blank.
    var displayTitle: String {
        goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title
    }
}
