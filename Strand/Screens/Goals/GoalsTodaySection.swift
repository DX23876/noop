import SwiftUI
import StrandDesign
import StrandAnalytics

/// Today's goals, in ONE card, shared by all four Today styles (Liquid, classic, Trends, Overview) so
/// every dashboard shows exactly the same goal truth.
///
/// What it shows, in this order:
/// - up to three goals, each drawn in its own shape: first the weekly, monthly or long-term goals that
///   need a look today, the rows still free filled with the wearer's long-term goals;
/// - today's daily goals as one row of chips, ticked off automatically or by hand;
/// - one line for the week and the month;
/// - "still open from the last days": the next-day question for goals NOOP could not see done (§17j);
/// - the "which goal did this workout support?" question, now only for workouts no goal claims (Q20).
///
/// Every row pushes into the goals overview or a goal's detail on the tab's own navigation stack, so
/// there is one place for goals and Back works the same everywhere.
struct GoalsTodaySection: View {
    /// True draws the "GOALS · All ›" head above the card (Liquid Today); false keeps it
    /// inside the card (classic, Trends, Overview).
    var headerOutside: Bool = false

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var periodGoals = PeriodGoalStore.shared
    @ObservedObject private var actions = GoalActionStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    @AppStorage(Self.inviteDismissedKey) private var inviteDismissed = false

    static let inviteDismissedKey = "goals.todayInviteDismissed"

    /// ONE enum-driven sheet host (the codebase's rule since #R2: two hosts on one view swallow each other).
    private enum Sheet: Identifiable {
        case attribution(GoalWorkoutAttributionSuggestion)
        case journey(UUID)
        /// A catalog goal's page, which Today shows as a sheet (its stack does not carry goal routes).
        case page(UUID)
        case edit(UUID)
        var id: String {
            switch self {
            case .attribution(let s): return "attribution-\(s.id)"
            case .journey(let id):    return "journey-\(id)"
            case .page(let id):       return "page-\(id)"
            case .edit(let id):       return "edit-\(id)"
            }
        }
    }
    @State private var sheet: Sheet?

    /// What this card shows, decided by the rule every small goal surface shares (`GoalSpotlight`): up to
    /// three goals, the ones that need a look first, the rows still free filled with long-term goals.
    private var spotlight: GoalSpotlight {
        GoalSpotlight.make(todayActions: tracking.todayActions, periodSnapshots: tracking.periodSnapshots,
                           longTerm: tracking.snapshots, pinnedLongTerm: GoalPrefs.pinnedLongTermIds,
                           maxRows: 3, fillsWithLongTerm: true)
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

    /// The goals first, each drawn in its own shape (a sum as a track with its pace mark, a weight goal as
    /// the way to its target, consistency as week dots), then today's daily goals as one row of chips, then
    /// one line for everything else. What is not shown is on the goals page.
    @ViewBuilder
    private var content: some View {
        let spot = spotlight
        ForEach(Array(spot.rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { Divider().overlay(StrandPalette.hairline) }
            spotlightRow(row)
        }
        if !tracking.todayActions.isEmpty {
            if !spot.rows.isEmpty { Divider().overlay(StrandPalette.hairline) }
            TodayDailyGoalsBlock(occurrences: tracking.todayActions, onToggleManual: toggleDaily)
        }
        GoalNotifyOffer(occurrences: tracking.todayActions)
        if let summary = spot.summary {
            NavigationLink(value: TabRoute.goals) {
                HStack(spacing: 6) {
                    Text(summary).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if spot.rows.isEmpty && tracking.todayActions.isEmpty && spot.summary == nil {
            // Only goals measured by kind are left and they are fine; say where they are instead of drawing nothing.
            NavigationLink(value: TabRoute.goals) {
                Text("Your long-term goals are on course. Add a daily goal to see your day here.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
        }
        if let badge = tracking.motivation?.unseen.first {
            NavigationLink(value: TabRoute.goals) {
                HStack(spacing: 10) {
                    BadgeMedal(badge: badge, diameter: 30, showsCaption: false)
                    Text(String(localized: "New badge: \(badge.title)"))
                        .font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: "chevron.right").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // Daily goals NOOP could not see done, asked the next day (§17j); above the workout question (Q13).
        MissedGoalsBlock(limit: 3)
        if let suggestion = tracking.pendingWorkoutAttributions.first {
            Button { sheet = .attribution(suggestion) } label: { attributionRow(suggestion) }
                .buttonStyle(.plain)
        }
    }

    /// A weekly, monthly or long-term goal: its name and state, where it stands in its own terms
    /// ("642 km of 1,000 km", "207.3 kg, target 190 kg"), and under it the goal drawn in its shape.
    @ViewBuilder
    private func spotlightRow(_ row: GoalSpotlight.Row) -> some View {
        switch row {
        case .period(let snapshot, let reason):
            NavigationLink(value: TabRoute.periodGoal(snapshot.id)) {
                GoalShapeRow(icon: snapshot.goal.metric.icon, tint: snapshot.identityColor,
                             title: GoalFormat.shortName(snapshot.goal), style: snapshot.style,
                             value: GoalFormat.progress(snapshot),
                             caption: reason == .reachedToday ? String(localized: "Reached today")
                                                              : GoalFormat.remainingLine(snapshot)) {
                    PeriodShapeGlyph(snapshot: snapshot)
                }
            }
            .buttonStyle(.plain)
            .contextMenu { periodMenu(snapshot) }
        case .longTerm(let snapshot, _):
            // Today nudges, it does not scold (plan §17g, Q14): a long-term goal at risk reads in amber
            // here (red stays on the goals page and the detail).
            let content = LongTermGoalContent(snapshot)
            let base = content?.style ?? GoalStatusStyle.of(snapshot.health)
            let style = base.tone == .critical
                ? GoalStatusStyle(word: base.word, wordText: base.wordText, symbol: base.symbol, tone: .warning)
                : base
            let tint = CoachIconColors.color(for: "coach.goal.\(snapshot.goal.kind.rawValue)")
            // A catalog goal opens its page; a goal measured by kind keeps its next step and its journey.
            Button { sheet = content == nil ? .journey(snapshot.id) : .page(snapshot.id) } label: {
                GoalShapeRow(icon: GoalCatalog.template(for: snapshot.goal)?.icon ?? snapshot.goal.kind.icon,
                             tint: tint, title: snapshot.displayTitle, style: style,
                             value: content?.heroValue ?? "",
                             caption: content?.heroCaption ?? snapshot.localizedNextAction) {
                    if let reading = snapshot.reading {
                        GoalShapeGlyph(reading: reading, tint: tint)
                    } else if let fraction = snapshot.displayProgress {
                        PaceTrack(fraction: fraction, tint: tint, height: 6)
                    }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                let pinned = GoalPrefs.pinnedLongTermIds.contains(snapshot.id)
                Button(pinned ? "Unpin from Today" : "Keep on Today", systemImage: pinned ? "pin.slash" : "pin") {
                    GoalPrefs.setPinned(snapshot.id, !pinned)
                    tracking.objectWillChange.send()
                }
            }
        }
    }

    private func toggleDaily(_ occurrence: GoalActionOccurrence) {
        actions.toggleManual(occurrence.action.id, day: occurrence.day)
        StrandHaptic.selection.play()
        Task { await tracking.refresh(repo: repo) }
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
        case .page(let id):
            NavigationStack { LongTermGoalPage(goalId: id) }
        case .edit(let id):
            PeriodGoalEditSheet(goalId: id) { Task { await tracking.refresh(repo: repo) } }
        }
    }

    // MARK: - Headers

    private var outsideHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            NavigationLink(value: TabRoute.goals) {
                Text(String(localized: "Goals").uppercased())
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
