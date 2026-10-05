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
/// - "still open from the last days": the next-day question for goals NOOP could not see done (§17j);
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

    /// What this card shows, decided by the rule every small goal surface shares (`GoalSpotlight`).
    private var spotlight: GoalSpotlight {
        GoalSpotlight.make(todayActions: tracking.todayActions, periodSnapshots: tracking.periodSnapshots,
                           longTerm: tracking.snapshots, pinnedLongTerm: GoalPrefs.pinnedLongTermIds)
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

    /// Daily goals first (rings, then boxes to tick), then at most two goals that need a look today,
    /// then one line for everything else (plan §17f). What is not shown is on the goals page.
    @ViewBuilder
    private var content: some View {
        let spot = spotlight
        // Up to three rings; the other daily goals as rows while there are one or two, else counted
        // in one strip ("6 of 10 daily goals done").
        let checksAsRows = spot.checks.count <= 2
        if !spot.rings.isEmpty || !checksAsRows {
            NavigationLink(value: TabRoute.goals) {
                DailyGoalRings(occurrences: tracking.todayActions, motivation: tracking.motivation, diameter: 92,
                               showsTally: !checksAsRows)
            }
            .buttonStyle(.plain)
        }
        if checksAsRows {
            ForEach(spot.checks) { occurrence in dailyRow(occurrence) }
        }
        GoalNotifyOffer(occurrences: tracking.todayActions)
        if !spot.rows.isEmpty {
            if !spot.rings.isEmpty || !spot.checks.isEmpty { Divider().overlay(StrandPalette.hairline) }
            ForEach(spot.rows) { row in spotlightRow(row) }
        }
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
        if spot.rings.isEmpty && spot.checks.isEmpty && spot.rows.isEmpty && spot.summary == nil {
            // Long-term goals that are fine stay off Today (Q7); say where they are instead of drawing nothing.
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

    /// A weekly, monthly or long-term goal in one compact line: why it is here, its name, what is left.
    @ViewBuilder
    private func spotlightRow(_ row: GoalSpotlight.Row) -> some View {
        switch row {
        case .period(let snapshot, let reason):
            NavigationLink(value: TabRoute.periodGoal(snapshot.id)) {
                compactRow(icon: snapshot.goal.metric.icon, tint: snapshot.identityColor,
                           title: GoalFormat.shortName(snapshot.goal),
                           detail: reason == .reachedToday
                               ? String(localized: "Reached today · \(GoalFormat.progress(snapshot))")
                               : "\(GoalFormat.progress(snapshot)) · \(GoalFormat.remainingLine(snapshot))",
                           style: snapshot.style, fraction: snapshot.result.fraction)
            }
            .buttonStyle(.plain)
            .contextMenu { periodMenu(snapshot) }
        case .longTerm(let snapshot, _):
            // Today nudges, it does not scold (plan §17g, Q14): a long-term goal at risk reads in amber
            // here (red stays on the goals page and the detail), and its line says what to do next.
            let base = GoalStatusStyle.of(snapshot.health)
            let style = snapshot.health == .atRisk
                ? GoalStatusStyle(word: base.word, wordText: base.wordText, symbol: base.symbol, tone: .warning)
                : base
            // A catalog goal says where it stands in its own terms ("642 km of 1,000 km · On track") and
            // opens its page; a goal measured by kind keeps its next step and its journey.
            let content = LongTermGoalContent(snapshot)
            Button { sheet = content == nil ? .journey(snapshot.id) : .page(snapshot.id) } label: {
                compactRow(icon: GoalCatalog.template(for: snapshot.goal)?.icon ?? snapshot.goal.kind.icon,
                           tint: CoachIconColors.color(for: "coach.goal.\(snapshot.goal.kind.rawValue)"),
                           title: snapshot.displayTitle,
                           detail: content.map { c in
                               ([c.heroValue] + [c.heroCaption].compactMap { $0 }).joined(separator: " ")
                                   + " · " + c.style.wordText
                           } ?? snapshot.localizedNextAction,
                           style: content.map { c in c.style.tone == .critical
                               ? GoalStatusStyle(word: c.style.word, wordText: c.style.wordText,
                                                 symbol: c.style.symbol, tone: .warning)
                               : c.style } ?? style,
                           fraction: snapshot.displayProgress)
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

    private func compactRow(icon: String, tint: Color, title: String, detail: String,
                            style: GoalStatusStyle, fraction: Double?) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: 3)
                if let fraction {
                    Circle().trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Label(style.wordText, systemImage: style.symbol)
                        .font(StrandFont.caption.weight(.semibold)).foregroundStyle(style.foreground)
                        .labelStyle(.titleAndIcon).lineLimit(1)
                }
                Text(detail).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
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
