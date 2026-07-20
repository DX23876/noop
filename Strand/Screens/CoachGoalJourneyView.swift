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
    private enum GoalConfirmation: Identifiable {
        case setAside(UUID), delete(UUID)
        var id: String {
            switch self {
            case .setAside(let id): return "setAside-\(id)"
            case .delete(let id):   return "delete-\(id)"
            }
        }
    }
    @State private var goalConfirmation: GoalConfirmation?
    /// Re-startable guided onboarding (#R12): offered whenever a goal slot is free, so the few-questions
    /// flow isn't a one-time first-run thing.
    @State private var showGuidedSetup = false

    private var activeGoals: [CoachGoal] { goalStore.activeGoals }
    private var canAddMore: Bool { activeGoals.count < CoachGoalStore.maxActiveGoals }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(expiredGoals) { g in expiredGoalCard(g) }
            ForEach(activeGoals) { g in goalCard(g) }
            if canAddMore {
                addGoalSection
            } else {
                maxReachedNote
            }
        }
        .sheet(item: $goalSheet) { which in
            switch which {
            case .edit(let id): CoachGoalEditorView(isOnboarding: false, editingGoalId: id)
            case .newGoal:      CoachGoalEditorView(isOnboarding: false)
            case .journey(let id): JourneyView(goalId: id).environmentObject(coach)
            }
        }
        .sheet(isPresented: $showGuidedSetup) {
            CoachGoalOnboardingFlow()
        }
        .confirmationDialog(goalConfirmationTitle,
                            isPresented: goalConfirmationIsPresented,
                            titleVisibility: .visible) {
            goalConfirmationActions
        } message: {
            goalConfirmationMessage
        }
    }

    // MARK: - Confirmation dialog (one enum-driven dialog — see R2)

    private var goalConfirmationIsPresented: Binding<Bool> {
        Binding(get: { goalConfirmation != nil }, set: { if !$0 { goalConfirmation = nil } })
    }

    private var goalConfirmationTitle: LocalizedStringKey {
        switch goalConfirmation {
        case .setAside: return "Set this goal aside?"
        case .delete:   return "Delete this goal?"
        case nil:       return ""
        }
    }

    @ViewBuilder
    private var goalConfirmationActions: some View {
        switch goalConfirmation {
        case .setAside(let id):
            Button("Injury or health") { goalStore.setAside(id, reason: "injury or health") }
            Button("Life got busy") { goalStore.setAside(id, reason: "life got busy") }
            Button("Priorities changed") { goalStore.setAside(id, reason: "priorities changed") }
            Button("No particular reason") { goalStore.setAside(id, reason: "") }
            Button("Cancel", role: .cancel) {}
        case .delete(let id):
            Button("Delete goal", role: .destructive) { goalStore.remove(id) }
            Button("Cancel", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var goalConfirmationMessage: some View {
        switch goalConfirmation {
        case .setAside: Text("It stays in your history — nothing is lost, and there's nothing to justify.")
        case .delete:   Text("This removes the goal and its history from the device. There is no undo.")
        case nil:       EmptyView()
        }
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
                Image(systemName: "sparkles").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
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
                            .foregroundStyle(StrandPalette.accent)
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
                            .foregroundStyle(StrandPalette.accent)
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
            Button("Set aside") { goalConfirmation = .setAside(goal.id) }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Button { goalConfirmation = .delete(goal.id) } label: {
                Image(systemName: "trash")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
            }
            .accessibilityLabel("Delete goal")
        }
        .buttonStyle(.plain)
    }

    /// Active goals whose target date has passed — a decision card per goal, not a dead end.
    private var expiredGoals: [CoachGoal] {
        activeGoals.filter { $0.status == .active && ($0.weeksRemaining() ?? 0) < 0 }
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
                    Button("Set aside") { goalConfirmation = .setAside(goal.id) }
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
        let gate = GoalSafetyGate.assess(goal: goal, bodyWeightKg: ProfileStore().weightKg)
        if gate.verdict == .aggressive || gate.verdict == .veryAggressive {
            parts.append(goal.acknowledgedRisk != nil ? "brisk pace, acknowledged" : "brisk pace")
        }
        return parts.isEmpty ? "No target date set" : parts.joined(separator: " · ")
    }
}
