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
    @ObservedObject private var goalStore = CoachGoalStore.shared
    /// Apple Health-style leading-icon coloring (SettingsView's "App icon colors") — same switch that
    /// recolors the More tab and the rest of Coach's screens. See `CoachIconColors`.
    @AppStorage("noop.moreRowAppleHealthColors") private var appleHealthColors = true

    private enum GoalSheet: Identifiable {
        case edit(UUID), newGoal, journey(UUID)
        var id: String {
            switch self {
            case .edit(let id):    return "edit-\(id)"
            case .newGoal:         return "newGoal"
            case .journey(let id): return "journey-\(id)"
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
            ForEach(expiredGoals) { g in expiredGoalCard(g) }
            ForEach(activeGoals) { g in goalCard(g) }
            if canAddMore {
                addGoalSection
            } else {
                maxReachedNote
            }
        }
        // ONE enum-driven sheet (#R2) — a second `.sheet(isPresented:)` alongside this used to stack two
        // sheet hosts on the same view, the classic SwiftUI glitch where dismissing one can intermittently
        // re-present or bounce back to whatever's underneath.
        .sheet(item: $goalSheet) { which in
            switch which {
            case .edit(let id): CoachGoalEditorView(isOnboarding: false, editingGoalId: id)
            case .newGoal:      CoachGoalEditorView(isOnboarding: false)
            case .journey(let id): JourneyView(goalId: id).environmentObject(coach)
            }
        }
        .navigationDestination(isPresented: $showGuidedSetup) {
            // `pushed: true` so the flow doesn't wrap itself in a second NavigationStack, and the same
            // `onClose` every other path passes, so finishing here also disarms the one-time offer in
            // CoachView — otherwise that offer stayed armed and could re-present the wizard mid-setup.
            CoachGoalOnboardingFlow(pushed: true) {
                UserDefaults.standard.set(true, forKey: CoachView.goalOnboardingAskedKey)
            }
        }
        // Literal titles + stored bindings — see the `showSetAsideConfirm` declaration for why the
        // previous single computed-Binding dialog froze this screen.
        .confirmationDialog("Set this goal aside?", isPresented: $showSetAsideConfirm,
                            titleVisibility: .visible) {
            if let id = setAsideGoalId {
                Button("Injury or health") { goalStore.setAside(id, reason: "injury or health") }
                Button("Life got busy") { goalStore.setAside(id, reason: "life got busy") }
                Button("Priorities changed") { goalStore.setAside(id, reason: "priorities changed") }
                Button("No particular reason") { goalStore.setAside(id, reason: "") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in your history — nothing is lost, and there's nothing to justify.")
        }
        .confirmationDialog("Delete this goal?", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            if let id = deleteGoalId {
                Button("Delete goal", role: .destructive) { goalStore.remove(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the goal and its history from the device. There is no undo.")
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
                            Text(goalSubtitle(goal))
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
            Button("Mark as achieved") { goalStore.markAchieved(goal.id) }
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
