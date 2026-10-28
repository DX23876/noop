import SwiftUI
import StrandDesign
import StrandAnalytics

/// The shared content (`LongTermGoalContent`) in Apple's design components.
extension LongTermGoalContent {
    var style: GoalStatusStyle { GoalStatusStyle(status) }
    var stats: [GoalHeroStat] {
        figures.map { GoalHeroStat(id: $0.id, label: $0.label, value: $0.value, fraction: $0.fraction) }
    }
}

extension MilestoneTrack.Point {
    init(_ point: LongTermGoalContent.Point) {
        let state: MilestoneTrack.PointState
        switch point.state {
        case .reached: state = .reached
        case .next: state = .next
        case .open: state = .open
        }
        self.init(id: point.id, label: point.label, state: state)
    }
}

extension WeekDotRow.Week {
    init(_ week: LongTermGoalContent.Week) {
        let state: WeekDotRow.WeekState
        switch week.state {
        case .kept: state = .kept
        case .almost: state = .almost
        case .missed: state = .missed
        case .protected: state = .protected
        case .noData: state = .noData
        case .running: state = .running
        }
        self.init(id: week.id, label: week.label, state: state)
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
    @State private var allMilestones: [MilestoneTrack.Point]?
    /// The latest AgeLess week's inputs while AgeLess is on, for the goal's AgeLess line.
    @State private var agelessWeek: HealthspanEngine.Inputs?

    private var snapshot: GoalTrackingSnapshot? { tracking.snapshot(for: goalId) }

    var body: some View {
        ScreenScaffold(title: nil, topBackground: liquidScaffoldSky()) {
            if let snapshot, let content = LongTermGoalContent(snapshot) {
                // Read top down: where the goal stands (hero, and a decision when one is due), the route,
                // what to do this week (the coach's tip), the figures behind it, then managing the goal.
                VStack(alignment: .leading, spacing: NoopMetrics.space6) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        LongTermGoalHero(snapshot: snapshot, content: content)
                        if snapshot.reading?.state == .achieved, snapshot.goal.status == .active {
                            reachedCard(snapshot)
                        }
                        if let week = agelessWeek, let years = AgeLessGoalLink.years(goal: snapshot.goal, week: week) {
                            NoopCard(padding: NoopMetrics.space3) {
                                Label(String(localized: "Worth about \(HealthspanSection.signedNumber(years)) years in AgeLess"),
                                      systemImage: "hourglass")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                            }
                        }
                        if let note = GoalConflicts.longTermNotes(goals.goals).first(where: { $0.goalId == goalId }) {
                            NoopCard(padding: NoopMetrics.space3) {
                                Label(note.text, systemImage: "exclamationmark.triangle")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningForeground)
                            }
                        }
                    }
                    if let band = content.band { bandSection(content.bandTitle, band) }
                    if let reading = snapshot.reading { LongTermGoalTipCard(goal: snapshot.goal, reading: reading) }
                    insightsSection(content.insights)
                    manageSection(snapshot)
                }
            } else if goals.goal(id: goalId)?.measure?.metric == .vo2max {
                // The VO₂max AgeLess reads has no reading in the goal's window yet: say how to give it one.
                Text(String(localized: "Wear your Apple Watch on walks, or enter a lab value."))
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("This goal has no page yet.")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await tracking.refresh(repo: repo) }
        .task { await loadAgeLessWeek() }
        .sheet(isPresented: $showJourney) { JourneyView(goalId: goalId) }
        .sheet(isPresented: $showRaise) { raiseSheet }
        .sheet(isPresented: Binding(get: { allMilestones != nil }, set: { if !$0 { allMilestones = nil } })) {
            MilestoneListSheet(points: allMilestones ?? [])
        }
    }

    /// The week the AgeLess line prices the goal against: the newest one, from the rows the AgeLess screens read.
    /// Nothing while AgeLess is off.
    private func loadAgeLessWeek() async {
        guard HealthspanFeature.isEnabled else { agelessWeek = nil; return }
        let profile = ProfileStore.persistedAnalyticsProfile
        guard let sex = HealthspanEngine.Sex(profileValue: profile.sex) else { return }
        agelessWeek = await HealthspanSnapshot.latestInputs(repo: repo, age: Int(profile.age), sex: sex)
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
                    Stepper(value: $raisedTarget, in: 0...100_000, step: LongTermFormat.raiseStep(metric, raisedTarget)) {
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

    /// A small uppercase heading over a section, with an optional action at its end ("All").
    private func sectionHeader(_ title: String, action: (label: LocalizedStringKey, run: () -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title).strandOverline()
            Spacer(minLength: NoopMetrics.space2)
            if let action {
                Button(action: action.run) {
                    Text(action.label).font(StrandFont.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
            }
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    private func bandSection(_ title: String, _ band: LongTermGoalContent.Band) -> some View {
        var action: (label: LocalizedStringKey, run: () -> Void)?
        if case .milestones(_, let before, let after, let all) = band, before || after {
            action = ("All", { allMilestones = all.map(MilestoneTrack.Point.init) })
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            sectionHeader(title, action: action)
            NoopCard(padding: NoopMetrics.space4) {
                switch band {
                case .milestones(let points, let before, let after, _):
                    MilestoneTrack(points: points.map(MilestoneTrack.Point.init), tint: StrandPalette.statusPositive,
                                   moreBefore: before, moreAfter: after)
                case .weeks(let weeks):
                    if weeks.isEmpty {
                        // A goal set this week has no finished week yet; an empty row would read as broken.
                        Text("The first week shows here once it ends.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        WeekDotRow(weeks: weeks.map(WeekDotRow.Week.init), tint: StrandPalette.statusPositive)
                    }
                case .columns(let values, let target, let higherIsBetter):
                    TargetColumns(values: values, target: target, tint: StrandPalette.accent, height: 90,
                                  higherIsBetter: higherIsBetter)
                }
            }
        }
    }

    /// The figures as one list: each row reads across, the column of values down the right edge.
    private func insightsSection(_ items: [LongTermGoalContent.Insight]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            sectionHeader(String(localized: "Insights"))
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        InsightRow(icon: item.icon, title: item.title, value: item.value,
                                   caption: item.caption, valueTone: item.tone.map(StrandTone.init))
                        if index < items.count - 1 { rowDivider }
                    }
                }
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.vertical, NoopMetrics.space1)
            }
        }
    }

    /// What can be done with the goal. Only the row that opens a page carries a chevron: pinning is a
    /// switch, pausing a menu of reasons.
    private func manageSection(_ snapshot: GoalTrackingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            sectionHeader(String(localized: "Manage"))
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    Button { showJourney = true } label: {
                        manageRow("Details and history", icon: "clock.arrow.circlepath", chevron: true)
                    }
                    .buttonStyle(.plain)
                    rowDivider
                    Toggle(isOn: Binding(get: { GoalPrefs.pinnedLongTermIds.contains(goalId) },
                                         set: { GoalPrefs.setPinned(goalId, $0); tracking.objectWillChange.send() })) {
                        manageRow("Keep on Today", icon: "pin")
                    }
                    .tint(StrandPalette.accent)
                    rowDivider
                    if snapshot.goal.status == .paused {
                        Button { goals.resume(goalId); refresh() } label: { manageRow("Resume", icon: "play.circle") }
                            .buttonStyle(.plain)
                    } else {
                        Menu {
                            ForEach(CoachGoal.PauseReason.allCases) { reason in
                                Button(reason.label.localizedCatalogValue) { goals.pause(goalId, reason: reason); refresh() }
                            }
                        } label: { manageRow("Pause", icon: "pause.circle") }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, NoopMetrics.space4)
            }
        }
    }

    /// The inset hairline between rows of one card, aligned with the row text.
    private var rowDivider: some View {
        Divider().overlay(StrandPalette.hairline).padding(.leading, 44)
    }

    private func manageRow(_ title: LocalizedStringKey, icon: String, chevron: Bool = false) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon).foregroundStyle(StrandPalette.accent).frame(width: 32).accessibilityHidden(true)
            Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
            }
        }
        .padding(.vertical, NoopMetrics.space3)
        .contentShape(Rectangle())
    }

    private func refresh() { Task { await tracking.refresh(repo: repo) } }
}

/// Every waypoint of a long route, from the bottom: the band shows five, this shows how far it all goes.
private struct MilestoneListSheet: View {
    let points: [MilestoneTrack.Point]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(points) { point in
                    HStack(spacing: 12) {
                        Image(systemName: point.state == .reached ? "checkmark.circle.fill"
                              : point.state == .next ? "circle.circle" : "circle")
                            .foregroundStyle(point.state == .open ? StrandPalette.textTertiary : StrandPalette.statusPositive)
                            .accessibilityHidden(true)
                        Text(verbatim: point.label)
                            .font(point.state == .next ? StrandFont.bodyNumber.weight(.semibold) : StrandFont.bodyNumber)
                            .foregroundStyle(point.state == .open ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                        Spacer()
                        if point.state == .next {
                            Text("Up next").font(StrandFont.caption).foregroundStyle(StrandPalette.statusPositive)
                        }
                    }
                    .id(point.id)
                }
                .onAppear {
                    if let next = points.first(where: { $0.state == .next }) { proxy.scrollTo(next.id, anchor: .center) }
                }
            }
            .navigationTitle(String(localized: "Milestones · \(points.filter { $0.state == .reached }.count) of \(points.count)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

/// The coach's tip under the insights (plan Q10, Q29): two sentences on this goal's own figures, new at
/// most once a day or when its state changes. Absent without the coach, a connection or data sharing,
/// and while the first tip is still on its way, so the page never shows an empty box. Tapping it opens
/// the coach with this goal as the topic.
private struct LongTermGoalTipCard: View {
    let goal: CoachGoal
    let reading: GoalShapeReading

    @EnvironmentObject private var coach: AICoachEngine
    @ObservedObject private var tips = LongTermGoalTipStore.shared
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachEnabled = false

    private var stateKey: String { reading.state?.rawValue ?? "none" }

    var body: some View {
        Group {
            if coachEnabled, LongTermGoalTipStore.allowed(reading, coach: coach),
               let tip = tips.current(for: goal.id, state: stateKey) {
                Button {
                    coach.openedFromCard(LongTermGoalTipStore.cardContext(goal: goal, reading: reading))
                    NotificationCenter.default.post(name: .noopOpenCoachCard, object: nil)
                } label: {
                    NoopCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Coach tip", systemImage: "sparkles")
                                .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                            Text(verbatim: tip.text)
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Ask the coach about this goal")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the AI coach with this goal's figures.")
            }
        }
        .task(id: stateKey) {
            guard coachEnabled else { return }
            await tips.refreshIfNeeded(goal: goal, reading: reading, coach: coach)
        }
    }
}
