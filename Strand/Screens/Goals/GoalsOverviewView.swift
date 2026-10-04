import SwiftUI
import StrandDesign
import StrandAnalytics

/// Navigation inside the goals area. Registered by the overview itself, so the area works the same
/// pushed onto a tab's stack, in the macOS sidebar, and inside the sheets the coach and Momentum open.
enum GoalsRoute: Hashable {
    case detail(UUID)
    case list(PeriodGoal.Period)
    case longTerm
    case archive
    case review
    case settings
    case setup(PeriodGoal.Period?)
}

/// The screen behind every "Goals" entry: Today's section head, the Today menu, More, the training hub,
/// the coach, the macOS sidebar. Replaces the former "Goal & Journey" page (its long-term content lives
/// on as the "Long-term" list).
struct GoalsOverviewScreen: View {
    @EnvironmentObject private var repo: Repository
    @State private var showIntro = false

    var body: some View {
        ScreenScaffold(title: "Goals", subtitle: "Today, this week, this month and beyond.",
                       onRefresh: { await GoalTrackingStore.shared.refresh(repo: repo) },
                       trailing: {
                           HStack(spacing: 14) {
                               Button { showIntro = true } label: { Image(systemName: "questionmark.circle") }
                                   .accessibilityLabel(Text("How goals work"))
                               NavigationLink(value: GoalsRoute.setup(nil)) { Image(systemName: "plus.circle.fill") }
                                   .accessibilityLabel(Text("New goal"))
                           }
                           .font(.title3)
                           .foregroundStyle(StrandPalette.accent)
                           .buttonStyle(.plain)
                       }) {
            GoalsOverviewView()
        }
        .goalsRouteDestinations()
        .sheet(isPresented: $showIntro) { GoalsIntroSheet() }
        .onAppear {
            // The explainer opens by itself once, on the first visit of the new overview (Q10), never
            // over Today.
            if !UserDefaults.standard.bool(forKey: GoalPrefs.introSeenKey) { showIntro = true }
        }
    }
}

/// Kept under its old name: the coach chat, Momentum, the classic Today and More all open it.
struct CoachGoalJourneyScreen: View {
    var body: some View { GoalsOverviewScreen() }
}

extension View {
    /// Every goals-area push. Apply once per stack root that hosts the goals area.
    func goalsRouteDestinations() -> some View {
        navigationDestination(for: GoalsRoute.self) { route in
            switch route {
            case .detail(let id): PeriodGoalDetailView(goalId: id)
            case .list(let period): PeriodGoalsListView(period: period)
            case .longTerm:
                ScreenScaffold(title: "Long-term goals", subtitle: "Your targets, your pace, your progress.") {
                    CoachGoalJourneyView()
                }
            case .archive: GoalsArchiveView()
            case .review: GoalsReviewScreen()
            case .settings: GoalsSettingsView()
            case .setup(let period): PeriodGoalSetupView(initialPeriod: period)
            }
        }
    }
}

struct GoalsOverviewView: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var periodGoals = PeriodGoalStore.shared
    @ObservedObject private var actions = GoalActionStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @AppStorage(GoalPrefs.crowdHintShownKey) private var crowdHintShown = false
    @AppStorage(HydrationStore.enabledKey) private var hydrationOn = false

    private enum Sheet: Identifiable {
        case journey(UUID), edit(UUID), dailyGoal(UUID?)
        var id: String {
            switch self {
            case .journey(let id): return "journey-\(id)"
            case .edit(let id): return "edit-\(id)"
            case .dailyGoal(let id): return "daily-\(id?.uuidString ?? "new")"
            }
        }
    }
    @State private var sheet: Sheet?
    @State private var showPaused = false
    @State private var hydrationML: Double?

    private func snapshots(_ period: PeriodGoal.Period) -> [PeriodGoalSnapshot] {
        tracking.periodSnapshots.filter { $0.goal.period == period && $0.goal.status == .active }
    }
    private var paused: [PeriodGoalSnapshot] { tracking.periodSnapshots.filter { $0.goal.status == .paused } }
    private var longTerm: [GoalTrackingSnapshot] {
        tracking.snapshots.filter { $0.goal.status == .active || $0.goal.status == .paused }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ladder
            chainQuestions
            linkOffers
            if !crowdHintShown, snapshots(.week).count > GoalPrefs.crowdThreshold { crowdHint }
            todaySection
            periodSection(.week)
            periodSection(.month)
            longTermSection
            reviewSection
            if !paused.isEmpty { pausedSection }
            NavigationLink(value: GoalsRoute.settings) {
                Label("Goal settings", systemImage: "gearshape")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .task {
            await tracking.refresh(repo: repo)
            if hydrationOn { hydrationML = await repo.hydrationTotal(day: Repository.localDayKey(Date())) }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .journey(let id): JourneyView(goalId: id)
            case .edit(let id): PeriodGoalEditSheet(goalId: id) { refresh() }
            case .dailyGoal(let id): GoalActionEditorView(editingId: id, onSave: refresh)
            }
        }
    }

    private func refresh() { Task { await tracking.refresh(repo: repo) } }

    // MARK: - Ladder

    private var ladder: some View {
        HStack(spacing: 8) {
            ladderTile(title: "Week", route: .list(.week), states: snapshots(.week).map(\.state))
            ladderTile(title: "Month", route: .list(.month), states: snapshots(.month).map(\.state))
            ladderTile(title: "Long-term", route: .longTerm,
                       states: longTerm.map { Self.periodState(for: $0.health) })
        }
    }

    /// The long-term health folded into the period vocabulary for the ladder's ring.
    static func periodState(for health: GoalTrackingSnapshot.Health) -> PeriodGoalState {
        switch health {
        case .onTrack: return .onTrack
        // A pending decision is a question for the wearer, not a goal falling behind.
        case .attention, .decisionNeeded: return .close
        case .atRisk: return .behind
        case .building: return .starting
        case .paused: return .protected
        }
    }

    private func ladderTile(title: LocalizedStringKey, route: GoalsRoute, states: [PeriodGoalState]) -> some View {
        let good = states.filter { [.onTrack, .ahead, .achieved].contains($0) }.count
        let warn = states.filter { $0 == .close }.count
        let bad = states.filter { $0 == .behind }.count
        let other = states.count - good - warn - bad
        return NavigationLink(value: route) {
            VStack(spacing: 6) {
                // The count is the reading ("2/3 on course"); the ring only shows how the rest splits.
                // Goals without a verdict yet are a light track, not a dark segment.
                ZStack {
                    GoalStatusRing(shares: [
                        .init(id: "good", count: good, tint: StrandPalette.statusPositive),
                        .init(id: "warn", count: warn, tint: StrandPalette.statusWarning),
                        .init(id: "bad", count: bad, tint: StrandPalette.statusCritical),
                        .init(id: "other", count: other, tint: StrandPalette.hairlineStrong),
                    ], lineWidth: 5, diameter: 52)
                    Text(states.isEmpty ? "–" : "\(good)/\(states.count)")
                        .font(StrandFont.headline).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .minimumScaleFactor(0.7).lineLimit(1)
                        .frame(width: 40)
                }
                Text(title).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(states.isEmpty ? String(localized: "None yet") : String(localized: "on course"))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(states.isEmpty ? String(localized: "None yet")
                                     : String(localized: "\(good) of \(states.count) on course")))
            .accessibilityHint(Text(title))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Sections

    private func sectionHeader(_ title: String, detail: String? = nil, route: GoalsRoute? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            if let detail {
                Text("· \(detail)").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 3) {
                        Text("All").font(StrandFont.caption)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(String(localized: "Today"))
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    if tracking.todayActions.isEmpty {
                        Text("Daily goals tick themselves off: steps, sleep, a workout, or a box you check.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(tracking.todayActions) { occurrence in
                        HStack(spacing: 9) {
                            Button {
                                guard case .manual = occurrence.action.requirement else { return }
                                actions.toggleManual(occurrence.action.id, day: occurrence.day)
                                StrandHaptic.selection.play()
                                refresh()
                            } label: {
                                DailyGoalIndicator(occurrence: occurrence)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(occurrence.isCompleted ? Text("Completed") : Text("Mark completed"))
                            Button { sheet = .dailyGoal(occurrence.action.id) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(occurrence.action.title)
                                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                    Text(occurrence.detailLine)
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if hydrationOn, let ml = hydrationML {
                        let goal = Double(repo.hydrationGoalML(profileSex: UserDefaults.standard.string(forKey: "profile.sex") ?? ""))
                        HStack(spacing: 9) {
                            Image(systemName: "drop.fill").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                            Text("Hydration").font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text(String(localized: "\((ml / 1000).formatted(.number.precision(.fractionLength(1)))) of \((goal / 1000).formatted(.number.precision(.fractionLength(1)))) l"))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                        }
                        PaceTrack(fraction: goal > 0 ? ml / goal : 0, tint: StrandPalette.accent, height: 4)
                    }
                    Button { sheet = .dailyGoal(nil) } label: {
                        Label("Add a daily goal", systemImage: "plus")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func periodSection(_ period: PeriodGoal.Period) -> some View {
        let items = snapshots(period)
        let days = items.first?.periodDays
            ?? PeriodGoalTracker.periodDays(period, containing: Repository.localDayKey(Date()),
                                            calendar: TrainingPreferences.weekCalendar)
        let today = Repository.localDayKey(Date())
        let left = days.filter { $0 >= today }.count
        let title = period == .week ? String(localized: "This week")
            : Date().formatted(.dateTime.month(.wide))
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title, detail: left == 1 ? String(localized: "last day") : String(localized: "\(left) days left"),
                          route: .list(period))
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty {
                        emptyPeriodInvite(period)
                    }
                    ForEach(items) { snapshot in
                        NavigationLink(value: GoalsRoute.detail(snapshot.id)) {
                            PeriodGoalRow(snapshot: snapshot)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { periodMenu(snapshot) }
                        if let parent = snapshot.goal.parentGoalId.flatMap({ goals.goal(id: $0) }) {
                            Text("↳ \(String(localized: "for")) \(parent.title.isEmpty ? parent.kind.label.localizedCatalogValue : parent.title)")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                .padding(.top, -10)
                        }
                    }
                }
            }
        }
    }

    private func emptyPeriodInvite(_ period: PeriodGoal.Period) -> some View {
        NavigationLink(value: GoalsRoute.setup(period)) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                Text(period == .week ? "No weekly goal yet. Add one" : "No monthly goal yet. Add one")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Image(systemName: "chevron.right").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var longTermSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(String(localized: "Long-term"), route: .longTerm)
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    if longTerm.isEmpty {
                        NavigationLink(value: GoalsRoute.longTerm) {
                            Text("A long-term goal gives your weeks a direction: a race, a weight, a habit.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(longTerm) { snapshot in
                        Button { sheet = .journey(snapshot.id) } label: { LongTermGoalRow(snapshot: snapshot) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                let pinned = GoalPrefs.pinnedLongTermIds.contains(snapshot.id)
                                Button(pinned ? "Unpin from Today" : "Keep on Today",
                                       systemImage: pinned ? "pin.slash" : "pin") {
                                    GoalPrefs.setPinned(snapshot.id, !pinned)
                                    tracking.objectWillChange.send()
                                }
                                NavigationLink(value: GoalsRoute.setup(.week)) {
                                    Label("Add a weekly goal for it", systemImage: "plus")
                                }
                            }
                    }
                }
            }
        }
    }

    private var reviewSection: some View {
        let lastWeek = snapshots(.week).compactMap(\.history.last)
        let achieved = lastWeek.filter { $0.outcome == .achieved }.count
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(String(localized: "Looking back"))
            NoopCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    NavigationLink(value: GoalsRoute.review) {
                        HStack {
                            Text(lastWeek.isEmpty ? String(localized: "Your weekly review appears after your first full week")
                                                  : String(localized: "Last week: \(achieved) of \(lastWeek.count) achieved"))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(StrandPalette.hairline)
                    NavigationLink(value: GoalsRoute.archive) {
                        HStack {
                            Text("Ended goals").font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pausedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(StrandMotion.fade) { showPaused.toggle() } } label: {
                HStack {
                    Text(String(localized: "Paused").uppercased())
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("\(paused.count)").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Image(systemName: showPaused ? "chevron.up" : "chevron.down")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .buttonStyle(.plain)
            if showPaused {
                NoopCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(paused) { snapshot in
                            HStack {
                                Text(GoalFormat.title(snapshot.goal))
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Button("Resume") {
                                    periodGoals.resume(snapshot.id)
                                    refresh()
                                }
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Questions and hints

    @ViewBuilder
    private var chainQuestions: some View {
        let pending = PeriodGoalStore.pendingChainQuestions
        let items = periodGoals.openGoals.filter { pending.contains($0.id) }
        ForEach(items) { goal in
            NoopCard(padding: 14, tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The goal \(GoalFormat.title(goal)) served has ended.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Keep it running as a habit, or end it too?")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: 16) {
                        Button("Keep it") { answerChain(goal.id, keep: true) }
                        Button("End it") { answerChain(goal.id, keep: false) }
                    }
                    .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Q2: weekly goal under an existing rate goal

    static let linkOfferDismissedKey = "goals.linkOfferDismissed"

    /// Long-term goals that are a weekly RATE ("4 sessions a week by December") and have no weekly goal
    /// serving them yet: offered once to get one that steps up with the plan.
    private var linkCandidates: [CoachGoal] {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.linkOfferDismissedKey) ?? [])
        let served = Set(periodGoals.openGoals.compactMap(\.parentGoalId))
        return goals.activeGoals.filter { goal in
            goal.status == .active && PeriodGoalTracker.rampMetric(for: goal.kind) != nil
                && !served.contains(goal.id) && !dismissed.contains(goal.id.uuidString)
        }
    }

    @ViewBuilder
    private var linkOffers: some View {
        ForEach(linkCandidates) { goal in
            let name = goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title
            NoopCard(padding: 14, tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a weekly goal that steps up with \(name)?")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("NOOP suggests each step at the start of a week; you confirm it.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button("Add weekly goal") { addLinkedWeekly(goal) }
                        Button("No thanks") { dismissLinkOffer(goal.id) }
                    }
                    .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func addLinkedWeekly(_ goal: CoachGoal) {
        guard let metric = PeriodGoalTracker.rampMetric(for: goal.kind) else { return }
        let start = goal.baseline ?? metric.defaultTarget(for: .week)
        var target = start
        if let end = goal.target, let date = goal.targetDate {
            let week = 7.0 * 86_400
            let total = max(1, Int((date.timeIntervalSince(goal.createdAt) / week).rounded()))
            let index = max(0, Int(Date().timeIntervalSince(goal.createdAt) / week))
            target = PeriodRampPlan.target(start: start, goal: end, totalWeeks: total, weekIndex: index,
                                           step: metric.step(for: .week))
        }
        let range = metric.range(for: .week)
        target = min(range.upperBound, max(range.lowerBound, target))
        let draft = PeriodGoal(metric: metric, period: .week, target: target, parentGoalId: goal.id)
        if periodGoals.canAdd(draft) == nil {
            periodGoals.commit(draft, today: Repository.localDayKey(Date()))
            StrandHaptic.commit.play()
        }
        dismissLinkOffer(goal.id)
        refresh()
    }

    private func dismissLinkOffer(_ id: UUID) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.linkOfferDismissedKey) ?? []
        dismissed.append(id.uuidString)
        UserDefaults.standard.set(dismissed, forKey: Self.linkOfferDismissedKey)
        tracking.objectWillChange.send()
    }

    private func answerChain(_ id: UUID, keep: Bool) {
        var pending = PeriodGoalStore.pendingChainQuestions
        pending.remove(id)
        PeriodGoalStore.pendingChainQuestions = pending
        if keep {
            if let index = periodGoals.goals.firstIndex(where: { $0.id == id }) {
                periodGoals.goals[index].parentGoalId = nil
            }
        } else {
            periodGoals.end(id)
        }
        refresh()
    }

    private var crowdHint: some View {
        NoopCard(padding: 14, tint: StrandPalette.statusWarning) {
            VStack(alignment: .leading, spacing: 8) {
                Text("More than four weekly goals get hard to follow. Want to pause one?")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    NavigationLink(value: GoalsRoute.list(.week)) { Text("Pause one") }
                    Button("Keep going") { crowdHintShown = true }
                }
                .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                .buttonStyle(.plain)
            }
        }
        .onDisappear { crowdHintShown = true }
    }

    @ViewBuilder
    private func periodMenu(_ snapshot: PeriodGoalSnapshot) -> some View {
        Button("Change goal", systemImage: "slider.horizontal.3") { sheet = .edit(snapshot.id) }
        Menu {
            ForEach(CoachGoal.PauseReason.allCases) { reason in
                Button(reason.label.localizedCatalogValue) {
                    periodGoals.pause(snapshot.id, reason: reason)
                    refresh()
                }
            }
        } label: { Label("Pause", systemImage: "pause") }
        Button("End goal", systemImage: "flag.checkered") {
            periodGoals.end(snapshot.id)
            refresh()
        }
    }
}
