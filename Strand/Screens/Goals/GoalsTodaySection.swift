import SwiftUI
import StrandDesign
import StrandAnalytics

/// Today's goals, in ONE card, shared by all four Today styles (Liquid, classic, Trends, Overview) so
/// every dashboard shows exactly the same goal truth.
///
/// What it shows, in this order (design §4):
/// - the week: the first three weekly goals in the order the wearer arranged (Q13), each a name, a state
///   word, a pace track and what is left; a line "+N need attention" when a goal below the fold slips;
/// - a long-term goal only when it needs a decision, is at risk, or is pinned (Q7);
/// - one line for the month;
/// - today's daily goals, ticked off automatically or by hand;
/// - the "which goal did this workout support?" question, now only for workouts no goal claims (Q20).
///
/// Every row pushes into the goals overview or a goal's detail on the tab's own navigation stack, so
/// there is one place for goals and Back works the same everywhere.
struct GoalsTodaySection: View {
    /// True draws the "GOALS · THIS WEEK · All ›" head above the card (Liquid Today); false keeps it
    /// inside the card (classic, Trends, Overview).
    var headerOutside: Bool = false

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var periodGoals = PeriodGoalStore.shared
    @ObservedObject private var actions = GoalActionStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @AppStorage(Self.inviteDismissedKey) private var inviteDismissed = false

    static let inviteDismissedKey = "goals.todayInviteDismissed"
    static let visibleWeekGoals = 3

    /// ONE enum-driven sheet host (the codebase's rule since #R2: two hosts on one view swallow each other).
    private enum Sheet: Identifiable {
        case attribution(GoalWorkoutAttributionSuggestion)
        case journey(UUID)
        case edit(UUID)
        var id: String {
            switch self {
            case .attribution(let s): return "attribution-\(s.id)"
            case .journey(let id):    return "journey-\(id)"
            case .edit(let id):       return "edit-\(id)"
            }
        }
    }
    @State private var sheet: Sheet?

    private var weekSnapshots: [PeriodGoalSnapshot] {
        tracking.periodSnapshots.filter { $0.goal.period == .week && $0.goal.isOpen }
    }
    private var monthSnapshots: [PeriodGoalSnapshot] {
        tracking.periodSnapshots.filter { $0.goal.period == .month && $0.goal.isOpen }
    }
    private var visibleWeek: [PeriodGoalSnapshot] { Array(weekSnapshots.prefix(Self.visibleWeekGoals)) }
    private var hiddenNeedingAttention: Int {
        weekSnapshots.dropFirst(Self.visibleWeekGoals).filter { GoalStatusStyle.needsAttention($0.state) }.count
    }
    private var longTermOnToday: [GoalTrackingSnapshot] {
        let pinned = GoalPrefs.pinnedLongTermIds
        return tracking.snapshots.filter { snapshot in
            snapshot.goal.status == .active
                && (pinned.contains(snapshot.id) || snapshot.health == .decisionNeeded || snapshot.health == .atRisk)
        }
    }
    private var hasAnyGoal: Bool {
        !periodGoals.openGoals.isEmpty || !goals.activeGoals.isEmpty || !tracking.todayActions.isEmpty
    }

    var body: some View {
        if hasAnyGoal {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                if headerOutside { outsideHeader }
                NoopCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !headerOutside { inCardHeader }
                        content
                    }
                }
            }
            .sheet(item: $sheet) { which in sheetContent(which) }
        } else if !inviteDismissed {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                if headerOutside { outsideHeader }
                GoalsInviteCard(onDismiss: { inviteDismissed = true })
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ForEach(visibleWeek) { snapshot in
            NavigationLink(value: TabRoute.periodGoal(snapshot.id)) {
                PeriodGoalRow(snapshot: snapshot)
            }
            .buttonStyle(.plain)
            .contextMenu { periodMenu(snapshot) }
        }
        if hiddenNeedingAttention > 0 {
            NavigationLink(value: TabRoute.goals) {
                Label(String(localized: "+\(hiddenNeedingAttention) more need attention"),
                      systemImage: "exclamationmark.circle")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningForeground)
            }
            .buttonStyle(.plain)
        }
        ForEach(longTermOnToday) { snapshot in
            Button { sheet = .journey(snapshot.id) } label: { LongTermGoalRow(snapshot: snapshot) }
                .buttonStyle(.plain)
                .contextMenu {
                    let pinned = GoalPrefs.pinnedLongTermIds.contains(snapshot.id)
                    Button(pinned ? "Unpin from Today" : "Keep on Today",
                           systemImage: pinned ? "pin.slash" : "pin") {
                        GoalPrefs.setPinned(snapshot.id, !pinned)
                        tracking.objectWillChange.send()
                    }
                }
        }
        if !monthSnapshots.isEmpty {
            if !visibleWeek.isEmpty || !longTermOnToday.isEmpty { Divider().overlay(StrandPalette.hairline) }
            NavigationLink(value: TabRoute.goals) { monthLine }.buttonStyle(.plain)
        }
        if !tracking.todayActions.isEmpty {
            if !visibleWeek.isEmpty || !monthSnapshots.isEmpty || !longTermOnToday.isEmpty {
                Divider().overlay(StrandPalette.hairline)
            }
            ForEach(Array(tracking.todayActions.prefix(3))) { occurrence in dailyRow(occurrence) }
            if tracking.todayActions.count > 3 {
                NavigationLink(value: TabRoute.goals) {
                    Text("All \(tracking.todayActions.count) daily goals")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        if visibleWeek.isEmpty && monthSnapshots.isEmpty && longTermOnToday.isEmpty && tracking.todayActions.isEmpty {
            // Long-term goals that are fine stay off Today (Q7); say where they are instead of drawing nothing.
            NavigationLink(value: TabRoute.goals) {
                Text("Your long-term goals are on course. Add a weekly goal to see your week here.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
        }
        if let suggestion = tracking.pendingWorkoutAttributions.first {
            Button { sheet = .attribution(suggestion) } label: { attributionRow(suggestion) }
                .buttonStyle(.plain)
        }
    }

    private var monthLine: some View {
        let onCourse = monthSnapshots.filter { [.onTrack, .ahead, .achieved].contains($0.state) }.count
        let behind = monthSnapshots.filter { GoalStatusStyle.needsAttention($0.state) }.count
        let month = Date().formatted(.dateTime.month(.wide))
        return HStack(spacing: 8) {
            Image(systemName: "calendar").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            Text(month).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 6)
            Text(behind > 0 ? String(localized: "\(onCourse) on course · \(behind) need attention")
                            : String(localized: "\(onCourse) of \(monthSnapshots.count) on course"))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Image(systemName: "chevron.right").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func dailyRow(_ occurrence: GoalActionOccurrence) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Button {
                guard case .manual = occurrence.action.requirement else { return }
                actions.toggleManual(occurrence.action.id, day: occurrence.day)
                StrandHaptic.selection.play()
                Task { await tracking.refresh(repo: repo) }
            } label: {
                DailyGoalIndicator(occurrence: occurrence)
            }
            .buttonStyle(.plain)
            .disabled(occurrence.isAutomatic || !isManual(occurrence.action.requirement))
            .accessibilityLabel(occurrence.isCompleted ? Text("Completed") : Text("Mark completed"))
            VStack(alignment: .leading, spacing: 1) {
                Text(occurrence.action.title)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                Text(occurrence.detailLine)
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func attributionRow(_ suggestion: GoalWorkoutAttributionSuggestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link.badge.plus").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Which goals did \(suggestion.workout.sport) support?")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                Text("Review a suggested multi-goal link")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func periodMenu(_ snapshot: PeriodGoalSnapshot) -> some View {
        Button("Change goal", systemImage: "slider.horizontal.3") { sheet = .edit(snapshot.id) }
        if snapshot.goal.status == .paused {
            Button("Resume", systemImage: "play") {
                periodGoals.resume(snapshot.id)
                Task { await tracking.refresh(repo: repo) }
            }
        } else {
            Menu {
                ForEach(CoachGoal.PauseReason.allCases) { reason in
                    Button(reason.label.localizedCatalogValue) {
                        periodGoals.pause(snapshot.id, reason: reason)
                        Task { await tracking.refresh(repo: repo) }
                    }
                }
            } label: { Label("Pause", systemImage: "pause") }
        }
        NavigationLink(value: TabRoute.periodGoal(snapshot.id)) { Label("Details", systemImage: "info.circle") }
    }

    @ViewBuilder
    private func sheetContent(_ which: Sheet) -> some View {
        switch which {
        case .attribution(let suggestion):
            GoalWorkoutAttributionSheet(suggestion: suggestion) { Task { await tracking.refresh(repo: repo) } }
        case .journey(let id):
            JourneyView(goalId: id)
        case .edit(let id):
            PeriodGoalEditSheet(goalId: id) { Task { await tracking.refresh(repo: repo) } }
        }
    }

    // MARK: - Headers

    private var outsideHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            NavigationLink(value: TabRoute.goals) {
                Text(String(localized: "Goals · This week").uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            Spacer()
            NavigationLink(value: TabRoute.goals) {
                HStack(spacing: 3) {
                    Text("All").font(StrandFont.caption)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Goals — open the goals overview"))
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private var inCardHeader: some View {
        NavigationLink(value: TabRoute.goals) {
            HStack {
                Label("Goals", systemImage: "target")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("All").font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                Image(systemName: "chevron.right")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Goals — open the goals overview"))
    }

    private func isManual(_ requirement: GoalAction.Requirement) -> Bool {
        if case .manual = requirement { return true }
        return false
    }
}

/// Shown on Today while no goal exists: one concrete weekly goal from the wearer's own data, created
/// with one tap, plus the way into the overview. Dismissable once (design §4.3).
struct GoalsInviteCard: View {
    let onDismiss: () -> Void
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var tracking = GoalTrackingStore.shared

    private var suggestion: (goal: PeriodGoal, usual: Double?) {
        let draft = PeriodGoal(metric: .workouts, period: .week, target: PeriodMetric.workouts.defaultTarget(for: .week))
        let rec = PeriodGoalTracker.recommendation(for: draft, inputs: tracking.periodInputs, now: Date(),
                                                   calendar: TrainingPreferences.weekCalendar)
        var goal = draft
        if let rec { goal.target = rec.recommended.value }
        return (goal, rec?.usual)
    }

    var body: some View {
        let s = suggestion
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Label("Set yourself a weekly goal", systemImage: "target")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Hide"))
                }
                Group {
                    if let usual = s.usual {
                        Text("You train about \(GoalFormat.number(usual, .workouts)) times a week. A goal of \(GoalFormat.number(s.goal.target, .workouts)) keeps you a little above that.")
                    } else {
                        Text("A weekly goal shows on Today how your week is going, at a glance.")
                    }
                }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button {
                        PeriodGoalStore.shared.commit(s.goal, today: Repository.localDayKey(Date()))
                        StrandHaptic.commit.play()
                        Task { await tracking.refresh(repo: repo) }
                    } label: {
                        Text("\(GoalFormat.number(s.goal.target, .workouts)) workouts a week")
                            .font(StrandFont.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    NavigationLink(value: TabRoute.goals) {
                        Text("Other goals").font(StrandFont.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }
}
