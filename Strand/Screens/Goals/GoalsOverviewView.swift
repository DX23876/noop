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
    case badges
}

/// The screen behind every "Goals" entry: Today's section head, the Today menu, More, the training hub,
/// the coach, the macOS sidebar. Replaces the former "Goal & Journey" page (its long-term content lives
/// on as the "Long-term" list).
struct GoalsOverviewScreen: View {
    @EnvironmentObject private var repo: Repository
    @State private var showIntro = false

    var body: some View {
        ScreenScaffold(title: "My goals", subtitle: "Tap a goal to change it.",
                       onRefresh: { await GoalTrackingStore.shared.refresh(repo: repo) },
                       topBackground: liquidScaffoldSky(),
                       trailing: {
                           HStack(spacing: 14) {
                               Button { showIntro = true } label: { Image(systemName: "questionmark.circle") }
                                   .accessibilityLabel(Text("How goals work"))
                               NavigationLink(value: GoalsRoute.setup(nil)) { Image(systemName: "plus.circle.fill") }
                                   .accessibilityLabel(Text("New goal"))
                                   #if os(macOS)
                                   .keyboardShortcut("n", modifiers: .command)
                                   .help(Text("New goal (⌘N)"))
                                   #endif
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
            // over Today; and whenever What's New sends the reader here for it.
            if !UserDefaults.standard.bool(forKey: GoalPrefs.introSeenKey) || GoalsIntroRequest.consume() {
                showIntro = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GoalsIntroRequest.notification)) { _ in
            // Already on screen (the macOS sidebar kept it), so onAppear will not run again.
            if GoalsIntroRequest.consume() { showIntro = true }
        }
    }
}

/// "Show me the goals explainer", raised by a What's New link. A flag plus a notification: the flag
/// covers the overview appearing afterwards, the notification an overview that is already showing.
@MainActor
enum GoalsIntroRequest {
    static let notification = Notification.Name("noop.goals.introRequested")
    private static var pending = false

    static func request() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// True once per request.
    static func consume() -> Bool {
        defer { pending = false }
        return pending
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
                ScreenScaffold(title: "Long-term goals", subtitle: "Your targets, your pace, your progress.",
                               topBackground: liquidScaffoldSky()) {
                    CoachGoalJourneyView()
                }
            case .archive: GoalsArchiveView()
            case .review: GoalsReviewScreen()
            case .settings: GoalsSettingsView()
            case .setup(let period): PeriodGoalSetupView(initialPeriod: period)
            case .badges: GoalBadgesView()
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
    @ObservedObject private var drafts = CoachGoalSetupProposalStore.shared
    @AppStorage(GoalPrefs.crowdHintShownKey) private var crowdHintShown = false
    @AppStorage(HydrationStore.enabledKey) private var hydrationOn = false

    private enum Sheet: Identifiable {
        case journey(UUID), edit(UUID), dailyGoal(UUID?), slot(DailyGoalSheet.Slot), draft(UUID)
        var id: String {
            switch self {
            case .draft(let id): return "draft-\(id)"
            case .journey(let id): return "journey-\(id)"
            case .edit(let id): return "edit-\(id)"
            case .dailyGoal(let id): return "daily-\(id?.uuidString ?? "new")"
            case .slot(let slot): return "slot-\(slot.rawValue)"
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

    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleColors = AppleInspiredColorsPrefs.defaultEnabled
    @State private var badgeBannerHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let motivation = tracking.motivation, !motivation.unseen.isEmpty, !badgeBannerHidden {
                NewBadgeBanner(badges: motivation.unseen) {
                    GoalPrefs.markBadgesSeen(motivation.unseen.map(\.id))
                    badgeBannerHidden = true
                }
            }
            if !drafts.pending.isEmpty {
                CoachSetupDraftsCard(proposals: drafts.pending) { sheet = .draft($0) }
            }
            ringsHero
            MissedGoalsBlock(inCard: true)
            chainQuestions
            linkOffers
            if !crowdHintShown, snapshots(.week).count > GoalPrefs.crowdThreshold { crowdHint }
            dailyList
            periodList(.week)
            periodList(.month)
            longTermList
            if let motivation = tracking.motivation {
                AchievementsCard(motivation: motivation)
            }
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
            case .slot(let slot): DailyGoalSheet(slot: slot, onSave: refresh)
            case .draft(let id): CoachGoalSetupReviewView(proposalId: id, onFinish: refresh)
            }
        }
    }

    private func refresh() { Task { await tracking.refresh(repo: repo) } }

    // MARK: - Today's rings

    @ViewBuilder
    private var ringsHero: some View {
        if !tracking.todayActions.isEmpty {
            NoopCard(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "Today")).strandOverline()
                    DailyGoalRings(occurrences: tracking.todayActions, motivation: tracking.motivation,
                                   showsLegend: false)
                    GoalNotifyOffer(occurrences: tracking.todayActions)
                }
            }
        } else if !UserDefaults.standard.bool(forKey: DailyGoalStarter.doneKey) {
            DailyGoalStarter(onDone: refresh)
        } else {
            NoopCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Start with a daily goal", systemImage: "target")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("Steps, sleep or active calories: a ring here fills up during the day.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { sheet = .slot(.steps) } label: {
                        Text("Set a step goal").font(StrandFont.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - The list

    /// A section of the list. An empty one folds down to its heading and the add line, without a card
    /// (plan §17g, Q8): an empty card per period made the page long for nothing.
    @ViewBuilder
    private func listSection<Content: View>(_ title: String, detail: String? = nil, route: GoalsRoute? = nil,
                                            isEmpty: Bool = false,
                                            @ViewBuilder content: () -> Content) -> some View {
        let rows = content()
        VStack(alignment: .leading, spacing: isEmpty ? 0 : 8) {
            sectionHeader(title, detail: isEmpty ? nil : detail, route: route)
            if isEmpty {
                rows.padding(.horizontal, 2)
            } else {
                NoopCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 4) { rows }
                }
            }
        }
    }

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

    private func addRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
            Text(title).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.accent)
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var today: String { Repository.localDayKey(Date()) }

    /// Goals measuring the same thing with different numbers; the note sits on the newer one (Q2).
    private var conflicts: [GoalConflicts.Note] {
        GoalConflicts.notes(actions: actions.actions, period: periodGoals.goals, longTerm: goals.goals, today: today)
    }

    private func warning(_ id: UUID?, in notes: [GoalConflicts.Note]) -> String? {
        guard let id else { return nil }
        return notes.first { $0.goalId == id }?.text
    }

    /// How long a daily goal runs, and on which days: "Ongoing · every day", "Until 31 Dec · Mon, Wed".
    private func runsLine(_ action: GoalAction) -> String {
        var parts: [String] = []
        // "Ongoing" is the normal case; only a run that ends says so (plan §17g).
        if let endsOn = action.endsOn {
            if endsOn == today { parts.append(String(localized: "Today only")) }
            else if let date = PeriodGoalTracker.date(endsOn, calendar: .autoupdatingCurrent) {
                parts.append(String(localized: "Until \(date.formatted(.dateTime.day().month(.abbreviated)))"))
            }
        }
        if endsOnIsNotToday(action) {
            switch action.schedule {
            case .daily: break   // every day is the default; saying it on every row is noise
            case .weekdays(let days):
                let symbols = Calendar.autoupdatingCurrent.shortStandaloneWeekdaySymbols
                parts.append(days.compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
                    .joined(separator: ", "))
            }
        }
        if let streak = tracking.motivation?.streaks[action.id]?.current, streak >= 2 {
            parts.append(String(localized: "\(streak) days in a row"))
        }
        return parts.joined(separator: " · ")
    }

    private func endsOnIsNotToday(_ action: GoalAction) -> Bool { action.endsOn != today }

    /// Where a daily goal stands today, then how long it runs: "7,328 of 10,000 steps · Ongoing · every day".
    /// A goal not due today says so instead of a reading.
    private func dailySubtitle(_ action: GoalAction, _ occurrence: GoalActionOccurrence?) -> String {
        // Today's state in words the target on the right does not repeat.
        let state: String
        if let occurrence {
            if occurrence.isCompleted { state = String(localized: "Done today") }
            else if occurrence.measured != nil { state = occurrence.detailLine }
            else { state = String(localized: "Not done yet") }
        } else {
            state = String(localized: "Not due today")
        }
        let runs = runsLine(action)
        return runs.isEmpty ? state : "\(state) · \(runs)"
    }

    private func isTick(_ requirement: GoalAction.Requirement) -> Bool {
        switch requirement {
        case .manual: return true
        case .workout(_, let minutes): return minutes == nil
        default: return false
        }
    }

    private var dailyList: some View {
        let slotActions = DailyGoalSheet.Slot.allCases.compactMap { $0.current(in: actions.actions, today: today)?.id }
        let others = actions.actions.filter {
            $0.isActive && !$0.hasEnded(today: today) && !slotActions.contains($0.id)
        }
        let notes = conflicts
        return listSection(String(localized: "Daily")) {
            ForEach(DailyGoalSheet.Slot.allCases) { slot in
                let action = slot.current(in: actions.actions, today: today)
                let occurrence = action.flatMap { a in tracking.todayActions.first { $0.action.id == a.id } }
                Button { sheet = .slot(slot) } label: {
                    GoalListRow(icon: slot.icon, tint: goalIdentityColor(slot.metric, appleColors: appleColors),
                                title: slot.title, subtitle: action.map { dailySubtitle($0, occurrence) },
                                value: action.flatMap { slot.value(of: $0.requirement) }.map(slot.format)
                                    ?? String(localized: "Off"),
                                valueIsOff: action == nil,
                                iconFraction: occurrence?.fraction ?? (occurrence?.isCompleted == true ? 1 : nil),
                                isDone: occurrence?.isCompleted ?? false,
                                warning: warning(action?.id, in: notes))
                }
                .buttonStyle(.plain)
            }
            if hydrationOn {
                let goal = Double(repo.hydrationGoalML(profileSex: UserDefaults.standard.string(forKey: "profile.sex") ?? ""))
                GoalListRow(icon: "drop.fill", tint: goalIdentityColor(.hydrationDays, appleColors: appleColors),
                            title: String(localized: "Hydration"),
                            subtitle: String(localized: "Set from your profile and the day's training"),
                            value: String(localized: "\((goal / 1000).formatted(.number.precision(.fractionLength(1)))) l"),
                            progress: hydrationML.map { goal > 0 ? $0 / goal : 0 })
            }
            ForEach(others) { action in
                let occurrence = tracking.todayActions.first { $0.action.id == action.id }
                Button { sheet = .dailyGoal(action.id) } label: {
                    GoalListRow(icon: icon(for: action.requirement),
                                tint: GoalActionOccurrence(action: action, day: today, isCompleted: false,
                                                           isAutomatic: false).identityColor(appleColors: appleColors),
                                title: action.title, subtitle: dailySubtitle(action, occurrence),
                                value: rowValue(action.requirement),
                                iconFraction: occurrence?.fraction ?? (occurrence?.isCompleted == true ? 1 : nil),
                                isDone: occurrence?.isCompleted ?? false,
                                warning: warning(action.id, in: notes),
                                isTick: isTick(action.requirement))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if case .manual = action.requirement, let occurrence {
                        Button(occurrence.isCompleted ? "Not done yet" : "Mark completed",
                               systemImage: occurrence.isCompleted ? "circle" : "checkmark.circle") {
                            actions.toggleManual(action.id, day: occurrence.day)
                            StrandHaptic.selection.play()
                            refresh()
                        }
                    }
                }
            }
            Button { sheet = .dailyGoal(nil) } label: { addRow(String(localized: "Add another daily goal")) }
                .buttonStyle(.plain)
        }
    }

    /// The short value on the right of a daily goal row; the subtitle carries the detail.
    private func rowValue(_ requirement: GoalAction.Requirement) -> String {
        switch requirement {
        case .journal: return String(localized: "Journal")
        case .manual: return String(localized: "By hand")
        default: return requirement.displayLabel
        }
    }

    private func icon(for requirement: GoalAction.Requirement) -> String {
        switch requirement {
        case .steps: return "figure.walk"
        case .sleep: return "moon.stars.fill"
        case .activeCalories: return "flame.fill"
        case .workout: return "figure.mixed.cardio"
        case .manual: return "checkmark.circle"
        case .journal: return "book.closed"
        }
    }

    private func periodList(_ period: PeriodGoal.Period) -> some View {
        let items = snapshots(period)
        let days = items.first?.periodDays
            ?? PeriodGoalTracker.periodDays(period, containing: today, calendar: TrainingPreferences.weekCalendar)
        let left = days.filter { $0 >= today }.count
        let notes = conflicts
        return listSection(period == .week ? String(localized: "Weekly") : String(localized: "Monthly"),
                           detail: left == 1 ? String(localized: "ends today") : String(localized: "\(left) days left"),
                           route: items.isEmpty ? nil : .list(period), isEmpty: items.isEmpty) {
            ForEach(items) { snapshot in
                NavigationLink(value: GoalsRoute.detail(snapshot.id)) {
                    GoalListRow(icon: snapshot.goal.metric.icon, tint: snapshot.identityColor,
                                title: GoalFormat.shortName(snapshot.goal),
                                subtitle: periodSubtitle(snapshot),
                                subtitleTint: GoalStatusStyle.needsAttention(snapshot.state) || snapshot.state == .achieved
                                    ? snapshot.style.foreground : StrandPalette.textSecondary,
                                value: GoalFormat.amount(snapshot.goal.target, snapshot.goal.metric),
                                progress: snapshot.state == .noData ? nil : snapshot.result.fraction,
                                dots: snapshot.goal.metric.aggregation == .hitDays && snapshot.goal.period == .week
                                    ? snapshot.dayDots() : nil,
                                columns: snapshot.goal.metric.aggregation == .average
                                    ? (snapshot.dayValues.enumerated().map { $0.offset <= snapshot.todayIndex ? $0.element : nil },
                                       snapshot.result.target) : nil,
                                warning: warning(snapshot.id, in: notes))
                }
                .buttonStyle(.plain)
                .contextMenu { periodMenu(snapshot) }
            }
            NavigationLink(value: GoalsRoute.setup(period)) {
                addRow(period == .week ? String(localized: "Add a weekly goal") : String(localized: "Add a monthly goal"))
            }
            .buttonStyle(.plain)
        }
    }

    private func periodSubtitle(_ snapshot: PeriodGoalSnapshot) -> String {
        var parts = ["\(GoalFormat.progress(snapshot)) · \(snapshot.style.wordText)"]
        if snapshot.currentStreak > 1 {
            parts.append(snapshot.goal.period == .week ? String(localized: "\(snapshot.currentStreak) weeks in a row")
                                                        : String(localized: "\(snapshot.currentStreak) months in a row"))
        }
        if let parent = snapshot.goal.parentGoalId.flatMap({ goals.goal(id: $0) }) {
            parts.append(String(localized: "for \(parent.title.isEmpty ? parent.kind.label.localizedCatalogValue : parent.title)"))
        }
        return parts.joined(separator: " · ")
    }

    private var longTermList: some View {
        listSection(String(localized: "Long-term"), route: longTerm.isEmpty ? nil : .longTerm,
                    isEmpty: longTerm.isEmpty) {
            ForEach(longTerm) { snapshot in
                let style = GoalStatusStyle.of(snapshot.health)
                Button { sheet = .journey(snapshot.id) } label: {
                    GoalListRow(icon: snapshot.goal.kind.icon,
                                tint: appleColors ? CoachIconColors.color(for: "coach.goal.\(snapshot.goal.kind.rawValue)")
                                                  : StrandPalette.accent,
                                title: snapshot.displayTitle,
                                subtitle: longTermSubtitle(snapshot, style: style),
                                subtitleTint: snapshot.health == .onTrack || snapshot.health == .building
                                    ? StrandPalette.textSecondary : style.foreground,
                                value: snapshot.goal.target.map {
                                    "\(GoalTrackingSnapshot.amountText($0, snapshot.goal.kind)) \(snapshot.goal.kind.displayUnit)"
                                } ?? "",
                                progress: snapshot.progressFraction)
                }
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
            NavigationLink { CoachGoalOnboardingFlow(pushed: true) } label: {
                addRow(String(localized: "Add a long-term goal"))
            }
            .buttonStyle(.plain)
        }
    }

    private func longTermSubtitle(_ snapshot: GoalTrackingSnapshot, style: GoalStatusStyle) -> String {
        guard let date = snapshot.goal.targetDate else { return style.wordText }
        return String(localized: "\(style.wordText) · by \(date.formatted(.dateTime.day().month(.abbreviated).year()))")
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
