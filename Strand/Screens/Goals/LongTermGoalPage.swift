import SwiftUI
import StrandDesign
import StrandAnalytics

/// Values of a catalog goal in the reader's format: kilometres, hours, kilos, a night's sleep.
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
        case .stepsTotal:
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
        case .recoveryAverage:
            return String(localized: "\(Int(value.rounded())) %")
        case .vo2max:
            return value.formatted(.number.precision(.fractionLength(1)))
        case .restingHr:
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
        case .trainingMinutes, .zoneMinutes: return String(localized: "\(n) min / week")
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

/// Everything a catalog goal's hero, band and insights show, worked out once from its snapshot.
struct LongTermGoalContent {

    enum Band {
        case milestones([MilestoneTrack.Point], moreBefore: Bool, moreAfter: Bool)
        case weeks([WeekDotRow.Week])
        case columns([Double?], target: Double, higherIsBetter: Bool)
    }

    struct Insight: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let value: String
        let caption: String?
        let tone: StrandTone?
    }

    let title: String
    let style: GoalStatusStyle
    let heroValue: String
    let heroCaption: String?
    let stats: [GoalHeroStat]
    let bandTitle: String
    let band: Band?
    let insights: [Insight]

    /// The style for a snapshot: the catalog reading's state where there is one, else the kind's health.
    static func style(_ snapshot: GoalTrackingSnapshot) -> GoalStatusStyle {
        if let state = snapshot.reading?.state { return GoalStatusStyle.of(state) }
        if snapshot.reading != nil {
            return GoalStatusStyle(word: "Running", wordText: String(localized: "Running"),
                                   symbol: "circle.dashed", tone: .neutral)
        }
        return GoalStatusStyle.of(snapshot.health)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init?(_ snapshot: GoalTrackingSnapshot) {
        guard let reading = snapshot.reading else { return nil }
        title = snapshot.displayTitle
        let style = Self.style(snapshot)
        self.style = style
        let toneOfState = style.tone

        switch reading {
        case .sum(let d):
            let r = d.reading
            heroValue = LongTermFormat.value(r.total, d.metric)
            heroCaption = String(localized: "of \(LongTermFormat.value(r.target, d.metric))")
            stats = [
                .init(id: 0, label: String(localized: "Target"), value: LongTermFormat.value(r.target, d.metric)),
                .init(id: 1, label: String(localized: "Progress"),
                      value: "\(Int((min(1, r.fraction) * 100).rounded())) %", fraction: min(1, r.fraction)),
                .init(id: 2, label: String(localized: "Estimated"),
                      value: r.projectedFinish.map(LongTermFormat.shortDate) ?? "–"),
            ]
            bandTitle = String(localized: "Milestones")
            band = Self.milestoneBand(d.milestones, metric: d.metric)
            var items: [Insight] = []
            items.append(.init(id: 0, icon: "speedometer", title: String(localized: "Current pace"),
                               value: r.recentWeeklyAverage.map { String(localized: "\(LongTermFormat.value($0, d.metric))/week") } ?? "–",
                               caption: r.recentWeeklyAverage == nil ? String(localized: "After four weeks of data")
                                                                      : style.wordText,
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
            heroCaption = String(localized: "target \(LongTermFormat.value(d.target, d.metric))")
            let next = d.milestones?.next
            stats = [
                .init(id: 0, label: String(localized: "Start"), value: LongTermFormat.value(d.baseline, d.metric)),
                .init(id: 1, label: String(localized: "Progress"),
                      value: "\(Int((d.progress * 100).rounded())) %", fraction: d.progress),
                .init(id: 2, label: String(localized: "Next mark"),
                      value: next.map { mark in
                          d.nextMarkDate.map { "\(LongTermFormat.value(mark, d.metric)) · \(LongTermFormat.shortDate($0))" }
                              ?? LongTermFormat.value(mark, d.metric)
                      } ?? "–"),
            ]
            bandTitle = String(localized: "Milestones")
            band = Self.milestoneBand(d.milestones, metric: d.metric)
            insights = [
                .init(id: 0, icon: "speedometer", title: String(localized: "Pace"),
                      value: d.ratePerWeek.map { String(localized: "\(LongTermFormat.signed($0, d.metric))/week") } ?? "–",
                      caption: d.ratePerWeek == nil ? String(localized: "After two weeks of readings") : style.wordText,
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
            let third: GoalHeroStat
            if let date = snapshot.goal.targetDate {
                let days = Calendar.autoupdatingCurrent.dateComponents([.day], from: Date(), to: date).day ?? 0
                third = .init(id: 2, label: String(localized: "Race day"),
                              value: days >= 0 ? LongTermFormat.inAbout(days: Double(days)) : LongTermFormat.shortDate(date))
            } else {
                third = .init(id: 2, label: String(localized: "Last best"),
                              value: r.daysSinceBest.map { $0 == 0 ? String(localized: "today")
                                  : String(localized: "\($0) days ago") } ?? "–")
            }
            stats = [
                .init(id: 0, label: String(localized: "Target"), value: LongTermFormat.value(target, .longestDistance)),
                .init(id: 1, label: String(localized: "Progress"),
                      value: r.fraction.map { "\(Int((min(1, $0) * 100).rounded())) %" } ?? "–",
                      fraction: r.fraction.map { min(1, $0) }),
                third,
            ]
            bandTitle = String(localized: "Milestones")
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
            stats = [
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
                               value: String(localized: "\(missed) of \(d.lastWeeks.count)"),
                               caption: r.share.map { String(localized: "\(Int(($0 * 100).rounded())) % kept") }, tone: nil))
            insights = items

        case .maintain(let d):
            let r = d.reading
            heroValue = r.latest.map { LongTermFormat.value($0, d.metric) } ?? "–"
            heroCaption = String(localized: "\(LongTermFormat.value(d.center, d.metric)) ± \(LongTermFormat.value(d.band, d.metric))")
            stats = [
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
            heroCaption = String(localized: "28-day average")
            stats = [
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

    private static func milestoneBand(_ window: LongTermGoalMath.MilestoneWindow?, metric: LongTermMetric) -> Band? {
        guard let window, !window.values.isEmpty else { return nil }
        let points = window.visible.map { index in
            MilestoneTrack.Point(id: index, label: LongTermFormat.value(window.values[index], metric),
                                 state: index < window.reachedCount ? .reached
                                     : index == window.reachedCount ? .next : .open)
        }
        return .milestones(points, moreBefore: window.visible.lowerBound > 0,
                           moreAfter: window.visible.upperBound < window.values.count)
    }

    private static func weekState(_ outcome: PeriodOutcome) -> WeekDotRow.WeekState {
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
    /// A count or a rate as a person says it: "3", "2.5".
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// The scene behind a goal's hero: today's day-cycle image in the motif the wearer picked.
struct LongTermGoalScene: View {
    @AppStorage(SceneMotif.storageKey) private var motifRaw = SceneMotif.defaultMotif.rawValue
    var body: some View {
        GoalHeroImage(name: DayCycleScene.assetName(hour: Calendar.current.component(.hour, from: Date()),
                                                    motif: SceneMotif.resolve(motifRaw)))
    }
}

/// A catalog goal's hero, compact for the overview list or full for its page.
struct LongTermGoalHero: View {
    let snapshot: GoalTrackingSnapshot
    let content: LongTermGoalContent
    var compact = false
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleColors = AppleInspiredColorsPrefs.defaultEnabled

    var body: some View {
        GoalHeroCard(title: content.title, stateWord: content.style.wordText, stateSymbol: content.style.symbol,
                     stateTone: content.style.tone,
                     icon: GoalCatalog.template(for: snapshot.goal)?.icon ?? snapshot.goal.kind.icon,
                     iconTint: appleColors ? CoachIconColors.color(for: "coach.goal.\(snapshot.goal.kind.rawValue)")
                                           : StrandPalette.accent,
                     heroValue: content.heroValue, heroCaption: content.heroCaption,
                     stats: content.stats, compact: compact, showsChevron: compact) {
            LongTermGoalScene()
        }
    }
}

/// The page of one catalog goal (plan §8.3): hero, band, insights, then the details that already exist
/// one tap away. Goals without a catalog reading keep opening their journey.
struct LongTermGoalPage: View {
    let goalId: UUID
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @ObservedObject private var goals = CoachGoalStore.shared
    @State private var showJourney = false
    @State private var showRaise = false
    @State private var raisedTarget: Double = 0

    private var snapshot: GoalTrackingSnapshot? { tracking.snapshot(for: goalId) }

    var body: some View {
        ScreenScaffold(title: nil, topBackground: liquidScaffoldSky()) {
            if let snapshot, let content = LongTermGoalContent(snapshot) {
                VStack(alignment: .leading, spacing: 18) {
                    LongTermGoalHero(snapshot: snapshot, content: content)
                    if snapshot.reading?.state == .achieved, snapshot.goal.status == .active {
                        reachedCard(snapshot)
                    }
                    if let note = GoalConflicts.longTermNotes(goals.goals).first(where: { $0.goalId == goalId }) {
                        Label(note.text, systemImage: "exclamationmark.triangle")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningForeground)
                    }
                    if let band = content.band { bandCard(content.bandTitle, band) }
                    insightsSection(content.insights)
                    moreSection(snapshot)
                }
            } else {
                Text("This goal has no page yet.")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await tracking.refresh(repo: repo) }
        .sheet(isPresented: $showJourney) { JourneyView(goalId: goalId) }
        .sheet(isPresented: $showRaise) { raiseSheet }
    }

    /// The goal reached (plan Q24): the wearer decides what happens next, nothing closes by itself.
    private func reachedCard(_ snapshot: GoalTrackingSnapshot) -> some View {
        let template = snapshot.goal.templateId.flatMap(GoalTemplateID.init(rawValue:))
        // Only a weight goal offers to keep what was reached; the line names just the buttons shown.
        let canKeep: Bool = {
            if template == .weightLose, case .target? = snapshot.reading { return true }
            return false
        }()
        return NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Goal reached", systemImage: "checkmark.seal.fill")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.statusPositive)
                Text(canKeep ? String(localized: "Close it, aim higher, or keep what you have reached.")
                             : String(localized: "Close it or aim higher."))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Close it") {
                        goals.markAchieved(goalId)
                        refresh()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Aim higher") {
                        raisedTarget = snapshot.goal.target ?? 0
                        showRaise = true
                    }
                    .buttonStyle(.bordered)
                    if template == .weightLose, case .target(let data)? = snapshot.reading {
                        Button("Keep the weight") { keepWeight(at: data.current, from: snapshot.goal) }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// Closes a reached weight loss and starts holding the weight it reached, in a band of one kilo.
    private func keepWeight(at weight: Double, from goal: CoachGoal) {
        goals.markAchieved(goal.id)
        let center = (weight * 2).rounded() / 2
        let keep = CoachGoal(kind: .weight, title: GoalCatalog.template(.weightMaintain)?.title.localizedCatalogValue ?? goal.title,
                             baseline: center, target: center,
                             templateId: GoalTemplateID.weightMaintain.rawValue,
                             measure: GoalMeasureSpec(metric: .weight, band: 1))
        goals.commit(keep)
        StrandHaptic.commit.play()
        refresh()
    }

    @ViewBuilder
    private var raiseSheet: some View {
        if let snapshot, let metric = snapshot.goal.measure?.metric {
            NavigationStack {
                Form {
                    Stepper(value: $raisedTarget, in: 0...100_000, step: Self.raiseStep(metric, raisedTarget)) {
                        HStack {
                            Text("New target")
                            Spacer()
                            Text(verbatim: LongTermFormat.value(raisedTarget, metric)).font(StrandFont.bodyNumber)
                        }
                    }
                }
                .navigationTitle(Text("Aim higher"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showRaise = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            var raised = snapshot.goal
                            raised.target = raisedTarget
                            goals.commit(raised, editingId: snapshot.goal.id)
                            showRaise = false
                            refresh()
                        }
                    }
                }
            }
        }
    }

    private static func raiseStep(_ metric: LongTermMetric, _ value: Double) -> Double {
        switch metric {
        case .distanceTotal: return value >= 200 ? 50 : 10
        case .longestDistance, .weight: return 0.5
        case .sleepAverage: return 0.25
        default: return 1
        }
    }

    private func bandCard(_ title: String, _ band: LongTermGoalContent.Band) -> some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                switch band {
                case .milestones(let points, let before, let after):
                    MilestoneTrack(points: points, tint: StrandPalette.statusPositive,
                                   moreBefore: before, moreAfter: after)
                case .weeks(let weeks):
                    WeekDotRow(weeks: weeks, tint: StrandPalette.statusPositive)
                case .columns(let values, let target, let higherIsBetter):
                    TargetColumns(values: values, target: target, tint: StrandPalette.accent, height: 90,
                                  higherIsBetter: higherIsBetter)
                }
            }
        }
    }

    private func insightsSection(_ items: [LongTermGoalContent.Insight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insights").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    InsightTile(icon: item.icon, title: item.title, value: item.value,
                                caption: item.caption, valueTone: item.tone)
                }
            }
        }
    }

    private func moreSection(_ snapshot: GoalTrackingSnapshot) -> some View {
        NoopCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Button { showJourney = true } label: {
                    moreRow("Details and history", icon: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                if snapshot.goal.status == .paused {
                    Button { goals.resume(goalId); refresh() } label: { moreRow("Resume", icon: "play.circle") }
                        .buttonStyle(.plain)
                } else {
                    Menu {
                        ForEach(CoachGoal.PauseReason.allCases) { reason in
                            Button(reason.label.localizedCatalogValue) { goals.pause(goalId, reason: reason); refresh() }
                        }
                    } label: { moreRow("Pause", icon: "pause.circle") }
                    .buttonStyle(.plain)
                }
                let pinned = GoalPrefs.pinnedLongTermIds.contains(goalId)
                Button {
                    GoalPrefs.setPinned(goalId, !pinned)
                    tracking.objectWillChange.send()
                } label: {
                    moreRow(pinned ? "Unpin from Today" : "Keep on Today", icon: pinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func moreRow(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(StrandPalette.accent).frame(width: 22).accessibilityHidden(true)
            Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func refresh() { Task { await tracking.refresh(repo: repo) } }
}
