import SwiftUI
import StrandDesign

/// The standalone screen behind the top-level "Goal & Journey" menu entry (#R6) — the same content as
/// the settings subpage, in the app's standard titled scaffold. Pushed from More (iOS) / the sidebar
/// (macOS), and presented from the coach chat's shortcut.
struct CoachGoalJourneyScreen: View {
    var body: some View {
        ScreenScaffold(title: "Goal & Journey",
                       subtitle: "Your target, your pace, your progress.") {
            CoachGoalJourneyView()
        }
        // TEMP DIAGNOSTIC (#freeze-investigation): timestamps the moment this screen is built, so the
        // analytics log lines can be read as before/during/after the tap. Remove with the other markers.
        .onAppear { NSLog("[FREEZE-DIAG] >>> CoachGoalJourneyScreen onAppear (Goal & Journey opened)") }
    }
}

/// The goal + journey surface (#R6, extended #R-multi-goal for several simultaneous goals), extracted
/// from `CoachSettingsView` so it can live in TWO places at once: still inside the settings hub, and now
/// as its own top-level entry (More on iOS, the sidebar on macOS) so a goal is one or two taps from
/// anywhere instead of five behind the chat's gear. Self-contained — it owns its goal editor / journey
/// sheets and its lifecycle confirmation dialogs (the same enum-driven presentation R2 gave the settings
/// version, so nothing here can regress into the stacked-sheet bug). The embedder supplies the scroll
/// scaffold and the title.
struct CoachGoalJourneyView: View {
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @ObservedObject private var actionStore = GoalActionStore.shared
    @ObservedObject private var trackingStore = GoalTrackingStore.shared
    @ObservedObject private var proposalStore = CoachGoalSetupProposalStore.shared
    /// Apple-inspired leading-icon coloring (SettingsView's "Apple-inspired colors") — same switch that
    /// recolors the More tab and the rest of Coach's screens. See `CoachIconColors`.
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleHealthColors = AppleInspiredColorsPrefs.defaultEnabled

    private enum GoalSheet: Identifiable {
        case edit(UUID), newGoal, journey(UUID), action(UUID?), proposal(UUID)
        var id: String {
            switch self {
            case .edit(let id):    return "edit-\(id)"
            case .newGoal:         return "newGoal"
            case .journey(let id): return "journey-\(id)"
            case .action(let id):  return "action-\(id?.uuidString ?? "new")"
            case .proposal(let id): return "proposal-\(id)"
            }
        }
    }
    @State private var goalSheet: GoalSheet?
    /// The guided setup is PUSHED, not presented (#coach-bugs): this view is reachable from inside a
    /// sheet (the chat's goal shortcut), and a sheet opened from a sheet is the stacked-host glitch this
    /// file already carries a scar from — here it showed up as the wizard resetting to its first step
    /// mid-setup. A push keeps one presentation host and one view identity.
    @State private var showGuidedSetup = false

    // Two separate confirmation dialogs, each with a LITERAL title and a stored `@State` Bool binding
    // (#goal-journey-freeze). This replaced a single enum-driven dialog whose `isPresented:` was a
    // Binding CONSTRUCTED FRESH inside a computed property on every body evaluation, and whose title was
    // a computed `LocalizedStringKey` that resolved to "" whenever nothing was being confirmed — i.e. in
    // the normal resting state. That combination put SwiftUI's confirmation-dialog machinery into a
    // re-evaluation loop that froze the screen the moment it opened, on BOTH routes to it (the chat's
    // shortcut and the settings subpage). Every other confirmation dialog in the app — DevicesView (3 of
    // them on one view), CoachSettingsView, JourneyView, CoachPlanView — already uses this
    // literal-title + stored-@State shape, which is why none of them ever showed the problem.
    @State private var setAsideGoalId: UUID?
    @State private var showSetAsideConfirm = false
    @State private var deleteGoalId: UUID?
    @State private var showDeleteConfirm = false
    @State private var pauseGoalId: UUID?
    @State private var showPauseConfirm = false
    @State private var showPastGoals = false

    /// TEMP DIAGNOSTIC (#goal-journey-freeze): body-evaluation counter, see `body`.
    nonisolated(unsafe) static var diagBodyCount = 0

    private var activeGoals: [CoachGoal] { goalStore.activeGoals }
    private var canAddMore: Bool { activeGoals.count < CoachGoalStore.maxActiveGoals }

    var body: some View {
        // TEMP DIAGNOSTIC (#goal-journey-freeze): counts body evaluations. A healthy open logs a
        // handful; a render loop logs hundreds within seconds. Remove once the fix is confirmed.
        let _ = { Self.diagBodyCount += 1
                  if Self.diagBodyCount % 10 == 0 || Self.diagBodyCount < 12 {
                      NSLog("[FREEZE-DIAG] CoachGoalJourneyView body eval #\(Self.diagBodyCount) goals=\(activeGoals.count) expired=\(expiredGoals.count)")
                  } }()
        VStack(spacing: 16) {
            if !proposalStore.pending.isEmpty { pendingSetupSection }
            if !activeGoals.isEmpty { portfolioSummary }
            ForEach(sortedActiveGoals) { g in goalCard(g) }
            if !activeGoals.isEmpty { goalActionsSection }
            if canAddMore {
                addGoalSection
            } else {
                maxReachedNote
            }
            if !pastGoals.isEmpty { pastGoalsSection }
        }
        .task { await trackingStore.refresh(repo: repo) }
        // ONE enum-driven sheet (#R2) — a second `.sheet(isPresented:)` alongside this used to stack two
        // sheet hosts on the same view, the classic SwiftUI glitch where dismissing one can intermittently
        // re-present or bounce back to whatever's underneath.
        .sheet(item: $goalSheet) { which in
            switch which {
            case .edit(let id): CoachGoalEditorView(isOnboarding: false, editingGoalId: id)
            case .newGoal:      CoachGoalEditorView(isOnboarding: false)
            case .journey(let id): JourneyView(goalId: id).environmentObject(coach)
            case .action(let id): GoalActionEditorView(editingId: id, onSave: refreshTracking)
            case .proposal(let id): CoachGoalSetupReviewView(proposalId: id, onFinish: refreshTracking)
            }
        }
        .navigationDestination(isPresented: $showGuidedSetup) {
            // `pushed: true` so the flow doesn't wrap itself in a second NavigationStack, and the same
            // `onClose` every other path passes, so finishing here also disarms the one-time offer in
            // CoachView — otherwise that offer stayed armed and could re-present the wizard mid-setup.
            CoachGoalOnboardingFlow(pushed: true) {
                UserDefaults.standard.set(true, forKey: CoachView.goalOnboardingAskedKey)
            }
            // Explicit rather than inherited: the flow's confirm step needs the engine for its
            // feasibility verdict, and stating it here keeps both presentation paths readable as the
            // same contract instead of one relying on the destination inheriting the environment.
            .environmentObject(coach)
        }
        // Literal titles + stored bindings — see the `showSetAsideConfirm` declaration for why the
        // previous single computed-Binding dialog froze this screen.
        .confirmationDialog("Set this goal aside?", isPresented: $showSetAsideConfirm,
                            titleVisibility: .visible) {
            if let id = setAsideGoalId {
                Button("Injury or health") { goalStore.setAside(id, reason: "injury or health"); refreshTracking() }
                Button("Life got busy") { goalStore.setAside(id, reason: "life got busy"); refreshTracking() }
                Button("Priorities changed") { goalStore.setAside(id, reason: "priorities changed"); refreshTracking() }
                Button("No particular reason") { goalStore.setAside(id, reason: ""); refreshTracking() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in your history — nothing is lost, and there's nothing to justify.")
        }
        .confirmationDialog("Delete this goal?", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            if let id = deleteGoalId {
                Button("Delete goal", role: .destructive) {
                    goalStore.remove(id)
                    actionStore.removeGoal(id)
                    GoalContributionStore.shared.removeGoal(id)
                    refreshTracking()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the goal and its history from the device. There is no undo.")
        }
        .confirmationDialog("Pause this goal?", isPresented: $showPauseConfirm,
                            titleVisibility: .visible) {
            if let id = pauseGoalId {
                ForEach(CoachGoal.PauseReason.allCases) { reason in
                    Button(reason.label.localizedCatalogValue) {
                        goalStore.pause(id, reason: reason)
                        refreshTracking()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Goal monitoring and flexible streaks freeze. Existing planned sessions stay in Your plan.")
        }
    }

    // MARK: - Confirmation helpers

    /// Arm the "set this goal aside" dialog for one goal. Payload and visibility are set together, so the
    /// dialog never renders without knowing which goal it is about.
    private func confirmSetAside(_ id: UUID) {
        setAsideGoalId = id
        showSetAsideConfirm = true
    }

    /// Arm the "delete this goal" dialog for one goal. Same pairing as `confirmSetAside`.
    private func confirmDelete(_ id: UUID) {
        deleteGoalId = id
        showDeleteConfirm = true
    }

    private func confirmPause(_ id: UUID) {
        pauseGoalId = id
        showPauseConfirm = true
    }

    private func refreshTracking() {
        Task { await trackingStore.refresh(repo: repo) }
    }

    private var pendingSetupSection: some View {
        NoopCard(padding: 14, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coach drafts").strandOverline()
                        Text("Nothing changes until you review and confirm.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                ForEach(Array(proposalStore.pending.prefix(3))) { proposal in
                    Button { goalSheet = .proposal(proposal.id) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proposal.goal?.goal.title ?? "Routine setup")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                                    .lineLimit(1)
                                Text(setupSummary(proposal))
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer(minLength: 8)
                            Text("Review").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func setupSummary(_ proposal: CoachGoalSetupProposal) -> String {
        let goalCount = proposal.goal == nil ? 0 : 1
        let routineCount = proposal.routines.count
        if goalCount == 1 && routineCount > 0 {
            return "1 goal · \(routineCount) routine\(routineCount == 1 ? "" : "s")"
        }
        if goalCount == 1 { return "1 goal" }
        return "\(routineCount) routine\(routineCount == 1 ? "" : "s")"
    }

    private var sortedActiveGoals: [CoachGoal] {
        activeGoals.sorted { lhs, rhs in
            let l = trackingStore.snapshot(for: lhs.id)
            let r = trackingStore.snapshot(for: rhs.id)
            let lh = l?.health.rawValue ?? GoalTrackingSnapshot.Health.building.rawValue
            let rh = r?.health.rawValue ?? GoalTrackingSnapshot.Health.building.rawValue
            if lh != rh { return lh < rh }
            return (lhs.targetDate ?? .distantFuture) < (rhs.targetDate ?? .distantFuture)
        }
    }

    private var pastGoals: [CoachGoal] {
        goalStore.goals
            .filter { $0.status == .achieved || $0.status == .abandoned || $0.status == .archived }
            .sorted { ($0.closure?.date ?? $0.createdAt) > ($1.closure?.date ?? $1.createdAt) }
    }

    private var portfolioSummary: some View {
        let snapshots = activeGoals.compactMap { trackingStore.snapshot(for: $0.id) }
        let stable = snapshots.filter { $0.health == .onTrack }.count
        let attention = snapshots.filter { $0.health == .attention }.count
        let action = snapshots.filter { $0.health == .atRisk || $0.health == .decisionNeeded }.count
        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your goals at a glance").strandOverline()
                HStack(spacing: 16) {
                    portfolioCount(stable, label: "on track", icon: "checkmark.circle")
                    portfolioCount(attention, label: "attention", icon: "eye.circle")
                    portfolioCount(action, label: "action", icon: "exclamationmark.circle")
                }
                if let first = sortedActiveGoals.first,
                   let snapshot = trackingStore.snapshot(for: first.id) {
                    Text(snapshot.nextAction)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func portfolioCount(_ count: Int, label: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).accessibilityHidden(true)
            Text("\(count) \(label)")
        }
        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Add a goal

    /// Guided setup stays the recommended path; the quick one-page editor is one tap away for anyone who'd
    /// rather fill it in all at once (#R12/#R-multi-goal — both paths persist through the same
    /// `CoachGoalStore.commit`, so they can never diverge on what's actually saved).
    private var addGoalSection: some View {
        VStack(spacing: 8) {
            guidedSetupButton
            Button { goalSheet = .newGoal } label: {
                Text(activeGoals.isEmpty ? "Or fill it in all at once" : "Add without the questions")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var guidedSetupButton: some View {
        Button { showGuidedSetup = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(appleHealthColors
                                     ? CoachIconColors.color(for: "coach.goalJourney.newGoal")
                                     : StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeGoals.isEmpty ? "Set up with a few questions" : "Add another goal")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("A short, guided setup.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StrandPalette.accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(StrandPalette.accent.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activeGoals.isEmpty ? "Set up your goal with a few questions" : "Add another goal")
    }

    private var maxReachedNote: some View {
        Text("You have the maximum of \(CoachGoalStore.maxActiveGoals) active goals. Set one aside or close one out to add another.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var goalActionsSection: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily actions").strandOverline()
                        Text("One action can support several goals.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Button { goalSheet = .action(nil) } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
                }
                if actionStore.actions.isEmpty {
                    Text("Add steps, a workout, or a manual check-off to make progress concrete today.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(actionStore.actions) { action in
                        Button { goalSheet = .action(action.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: action.isActive ? "checkmark.circle" : "pause.circle")
                                    .foregroundStyle(StrandPalette.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(action.title).font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text("\(action.requirement.label) · \(action.goalIds.count) goals")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private func goalCard(_ goal: CoachGoal) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                Button { goalSheet = .edit(goal.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: goal.kind.icon)
                            .foregroundStyle(appleHealthColors
                                            ? CoachIconColors.color(for: "coach.goal.\(goal.kind.rawValue)")
                                            : StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title)
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            Text(trackingStore.snapshot(for: goal.id)?.health.label.localizedCatalogValue
                                 ?? goalSubtitle(goal))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit your \(goal.kind.label.localizedCatalogValue) goal")

                Divider().overlay(StrandPalette.hairline)
                if let snapshot = trackingStore.snapshot(for: goal.id) {
                    goalTrackingSummary(snapshot)
                    Divider().overlay(StrandPalette.hairline)
                }
                Button { goalSheet = .journey(goal.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(appleHealthColors
                                             ? CoachIconColors.color(for: "coach.goalJourney.progress")
                                             : StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("View your journey")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View your journey — progress, milestones and plan history")

                Divider().overlay(StrandPalette.hairline)
                goalLifecycleRow(goal)
            }
        }
    }

    /// A goal must be able to END: close it as reached, set it aside, or delete it entirely.
    private func goalLifecycleRow(_ goal: CoachGoal) -> some View {
        HStack(spacing: 16) {
            if goal.status == .paused {
                Button("Resume") { goalStore.resume(goal.id); refreshTracking() }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            } else {
                Button("Pause") { confirmPause(goal.id) }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            Button("Achieved") { goalStore.markAchieved(goal.id); refreshTracking() }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            Button("Set aside") { confirmSetAside(goal.id) }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Button { confirmDelete(goal.id) } label: {
                Image(systemName: "trash")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
            }
            .accessibilityLabel("Delete goal")
        }
        .buttonStyle(.plain)
    }

    private func goalTrackingSummary(_ snapshot: GoalTrackingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let measurement = snapshot.measurement {
                HStack {
                    Text(measurementLine(snapshot.goal, value: measurement.value))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(JourneyExplain.label(for: snapshot.trend.verdict))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if let fraction = snapshot.progressFraction {
                    ProgressView(value: fraction).appleInspiredTint("journey.nextStep")
                }
            }
            HStack {
                Text("Plan \(snapshot.currentWeek.planCompleted)/\(snapshot.currentWeek.planPlanned)")
                Text("Actions \(snapshot.currentWeek.actionCompleted)/\(snapshot.currentWeek.actionPlanned)")
                Spacer()
                Text("Series \(snapshot.currentStreak) · best \(snapshot.bestStreak)")
            }
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Text(snapshot.reason)
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(snapshot.nextAction)
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.health == .decisionNeeded,
               (ProactiveCoach.daysPastTarget(snapshot.goal) ?? 0) >= 1 {
                HStack(spacing: 14) {
                    Button("I reached it") { goalStore.markAchieved(snapshot.id); refreshTracking() }
                    Button("Extend") { goalSheet = .edit(snapshot.id) }
                    Button("Set aside") { confirmSetAside(snapshot.id) }
                }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                .buttonStyle(.plain)
            }
        }
    }

    private func measurementLine(_ goal: CoachGoal, value: Double) -> String {
        if let target = goal.target {
            return String(format: "%.1f %@ now · target %.1f %@", value, goal.kind.unit, target, goal.kind.unit)
        }
        return String(format: "%.1f %@ now", value, goal.kind.unit)
    }

    private var pastGoalsSection: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(StrandMotion.fade) { showPastGoals.toggle() } } label: {
                    HStack {
                        Text("Past goals").strandOverline()
                        Spacer()
                        Text("\(pastGoals.count)")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Image(systemName: showPastGoals ? "chevron.up" : "chevron.down")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                if showPastGoals {
                    ForEach(pastGoals) { goal in
                        Button { goalSheet = .journey(goal.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: goal.status == .achieved ? "checkmark.seal" : "archivebox")
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title)
                                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                                    Text(pastGoalLine(goal))
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func pastGoalLine(_ goal: CoachGoal) -> String {
        let status = goal.status == .achieved ? "Achieved" : "Set aside"
        guard let date = goal.closure?.date else { return status }
        return status + " · " + date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Active goals whose target date has passed — a decision card per goal, not a dead end. Same
    /// day-based, 1-day-grace threshold as `ProactiveCoach.expiredGoalNeedingReview`, so this card and the
    /// chat's unprompted goal review never disagree about whether a goal counts as overdue yet.
    private var expiredGoals: [CoachGoal] {
        activeGoals.filter { $0.status == .active && (ProactiveCoach.daysPastTarget($0) ?? 0) >= 1 }
    }

    private func expiredGoalCard(_ goal: CoachGoal) -> some View {
        NoopCard(padding: 14, tint: StrandPalette.statusWarning) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .accessibilityHidden(true)
                    Text("Your \(goal.kind.label.localizedCatalogValue) target date has passed")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("How did it go? Close it out, give it more time, or set it aside — your call.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("I reached it") { goalStore.markAchieved(goal.id) }
                        .foregroundStyle(StrandPalette.accent)
                    Button("Extend the date") { goalSheet = .edit(goal.id) }
                        .foregroundStyle(StrandPalette.accent)
                    Button("Set aside") { confirmSetAside(goal.id) }
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .font(StrandFont.footnote)
                .buttonStyle(.plain)
            }
        }
    }

    /// One honest line: how long is left, whether the pace was flagged.
    private func goalSubtitle(_ goal: CoachGoal) -> String {
        var parts: [String] = []
        if let weeks = goal.weeksRemaining() {
            parts.append(weeks < 0 ? "target date passed"
                                   : String(format: "%.0f weeks to go", weeks.rounded()))
        }
        // Plain read — NEVER `ProfileStore()` here: that initialiser writes to UserDefaults, and doing
        // that inside a body evaluation forced this screen's second layout pass (#goal-journey-freeze).
        let gate = GoalSafetyGate.assess(goal: goal, bodyWeightKg: ProfileStore.persistedWeightKg)
        if gate.verdict == .aggressive || gate.verdict == .veryAggressive {
            parts.append(goal.acknowledgedRisk != nil ? "brisk pace, acknowledged" : "brisk pace")
        }
        return parts.isEmpty ? "No target date set" : parts.joined(separator: " · ")
    }
}
