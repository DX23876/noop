import SwiftUI
import StrandDesign

/// Shared by classic and liquid Today so both dashboards show exactly the same goal/action truth.
struct GoalTodaySection: View {
    @Binding var showGoalJourney: Bool
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var actions = GoalActionStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared
    /// The same "Apple-inspired colors" switch the rest of Coach honours; off means one accent for every
    /// goal kind instead of the per-kind palette.
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleHealthColors = AppleInspiredColorsPrefs.defaultEnabled
    @State private var attribution: GoalWorkoutAttributionSuggestion?

    /// Which goal leads. The rule lives on the store so this card and the iOS goal widget can never lead
    /// with different goals.
    private var primary: GoalTrackingSnapshot? { tracking.primarySnapshot }

    var body: some View {
        if !goals.activeGoals.isEmpty || !tracking.todayActions.isEmpty {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 10) {
                    Button { showGoalJourney = true } label: {
                        HStack {
                            Label("Goals today", systemImage: "target")
                                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    if let primary { primaryGoalRow(primary) }

                    if let suggestion = tracking.pendingWorkoutAttributions.first {
                        Button { attribution = suggestion } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "link.badge.plus")
                                    .foregroundStyle(StrandPalette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Which goals did \(suggestion.workout.sport) support?")
                                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                                    Text("Review a suggested multi-goal link")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(Array(tracking.todayActions.prefix(3))) { occurrence in
                        actionRow(occurrence)
                    }

                    if tracking.todayActions.isEmpty {
                        Text("Add a daily action to turn a long-term goal into something concrete today.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if tracking.todayActions.count > 3 {
                        Button("Show all \(tracking.todayActions.count) actions") { showGoalJourney = true }
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                            .buttonStyle(.plain)
                    }
                }
            }
            .sheet(item: $attribution) { suggestion in
                GoalWorkoutAttributionSheet(suggestion: suggestion) {
                    Task { await tracking.refresh(repo: repo) }
                }
            }
        }
    }

    /// The leading goal, given the weight it deserves: its mark or its progress as a ring in the goal
    /// kind's own colour, with the name and health verdict beside it and the week's counters underneath.
    ///
    /// The ring is drawn ONLY from `progressFraction`, which the tracking engine leaves nil unless a real
    /// measurement and both ends of the range exist. Without one the goal shows its mark instead — a
    /// filled circle on a home screen is read as achievement at a glance, and there is no room there to
    /// explain that it meant something else.
    private func primaryGoalRow(_ primary: GoalTrackingSnapshot) -> some View {
        let tint = goalTint(primary.goal.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                goalMark(primary, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary.goal.title.isEmpty
                         ? primary.goal.kind.label.localizedCatalogValue : primary.goal.title)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(primary.health.label.localizedCatalogValue)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("Plan \(primary.currentWeek.planCompleted)/\(primary.currentWeek.planPlanned)")
                Text("Actions \(primary.currentWeek.actionCompleted)/\(primary.currentWeek.actionPlanned)")
                Spacer()
                Text("Series \(primary.currentStreak)")
            }
            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    @ViewBuilder
    private func goalMark(_ primary: GoalTrackingSnapshot, tint: Color) -> some View {
        if let progress = primary.progressFraction {
            GlowRing(fraction: progress,
                     value: progress * 100,
                     format: { String(format: "%.0f%%", $0) },
                     color: tint,
                     diameter: 54, lineWidth: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        } else {
            Image(systemName: primary.goal.kind.icon)
                .font(.system(size: 21))
                .foregroundStyle(tint)
                .frame(width: 54, height: 54)
                .background(Circle().fill(tint.opacity(0.12)))
                .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }

    /// The goal kind's identity colour, honouring the same switch the rest of Coach reads.
    private func goalTint(_ kind: CoachGoal.Kind) -> Color {
        appleHealthColors ? CoachIconColors.color(for: "coach.goal.\(kind.rawValue)")
                          : StrandPalette.accent
    }

    private func actionRow(_ occurrence: GoalActionOccurrence) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                guard case .manual = occurrence.action.requirement else { return }
                actions.toggleManual(occurrence.action.id, day: occurrence.day)
                Task { await tracking.refresh(repo: repo) }
            } label: {
                Image(systemName: occurrence.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(occurrence.isCompleted ? StrandPalette.accent : StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(occurrence.isAutomatic || !isManual(occurrence.action.requirement))
            .accessibilityLabel(occurrence.isCompleted ? "Completed" : "Mark completed")

            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.action.title)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textPrimary)
                Text(occurrence.action.requirement.label.localizedCatalogValue)
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                let linked = goals.goals.filter { occurrence.action.goalIds.contains($0.id) }
                if !linked.isEmpty {
                    Text(linked.map { $0.title.isEmpty ? $0.kind.label.localizedCatalogValue : $0.title }
                        .joined(separator: " · "))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func isManual(_ requirement: GoalAction.Requirement) -> Bool {
        if case .manual = requirement { return true }
        return false
    }
}

struct GoalWorkoutAttributionSheet: View {
    let suggestion: GoalWorkoutAttributionSuggestion
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var contributions = GoalContributionStore.shared
    @State private var selected: Set<UUID>

    init(suggestion: GoalWorkoutAttributionSuggestion, onChange: @escaping () -> Void) {
        self.suggestion = suggestion
        self.onChange = onChange
        _selected = State(initialValue: Set(suggestion.suggestedGoalIds))
    }

    private var eligibleGoals: [CoachGoal] {
        goals.goals.filter { $0.status == .active || selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(suggestion.workout.sport).font(StrandFont.headline)
                    Text(Date(timeIntervalSince1970: Double(suggestion.workout.startTs))
                        .formatted(date: .abbreviated, time: .shortened))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                Section("Supports goals") {
                    ForEach(eligibleGoals) { goal in
                        Button {
                            if selected.contains(goal.id) { selected.remove(goal.id) }
                            else { selected.insert(goal.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(goal.id) ? "checkmark.circle.fill" : "circle")
                                Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button("This activity supports none of these", role: .destructive) {
                        contributions.dismiss(suggestion.id); onChange(); dismiss()
                    }
                }
            }
            .navigationTitle("Link activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let ordered = eligibleGoals.map(\.id).filter { selected.contains($0) }
                        contributions.confirm(suggestion.workout, goalIds: ordered)
                        onChange(); dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

struct GoalActionEditorView: View {
    let editingId: UUID?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = GoalActionStore.shared
    @ObservedObject private var goals = CoachGoalStore.shared

    private enum Kind: String, CaseIterable, Identifiable {
        case steps, workout, manual
        var id: String { rawValue }
        var label: String {
            switch self { case .steps: return "Steps"; case .workout: return "Workout"; case .manual: return "Manual" }
        }
    }

    @State private var title = ""
    @State private var kind: Kind = .steps
    @State private var steps = 10_000
    @State private var workout = "Walking"
    @State private var minimumMinutes = 20
    @State private var hasMinimum = true
    @State private var daily = true
    @State private var weekdays: Set<Int> = Set(1...7)
    @State private var goalIds: Set<UUID> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Action") {
                    TextField("Name", text: $title)
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.label.localizedCatalogValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if kind == .steps {
                        Stepper("\(steps.formatted()) steps", value: $steps, in: 1_000...50_000, step: 500)
                    } else if kind == .workout {
                        TextField("Activity, e.g. Walking", text: $workout)
                        Toggle("Minimum duration", isOn: $hasMinimum)
                        if hasMinimum {
                            Stepper("\(minimumMinutes) minutes", value: $minimumMinutes, in: 5...240, step: 5)
                        }
                    }
                }
                Section("Schedule") {
                    Toggle("Every day", isOn: $daily)
                    if !daily {
                        HStack {
                            ForEach(1...7, id: \.self) { weekday in
                                Button(shortWeekday(weekday)) {
                                    if weekdays.contains(weekday) { weekdays.remove(weekday) }
                                    else { weekdays.insert(weekday) }
                                }
                                .buttonStyle(.bordered)
                                .tint(weekdays.contains(weekday) ? StrandPalette.accent : StrandPalette.textTertiary)
                            }
                        }
                    }
                }
                Section("Supports goals") {
                    ForEach(goals.activeGoals) { goal in
                        Button {
                            if goalIds.contains(goal.id) { goalIds.remove(goal.id) } else { goalIds.insert(goal.id) }
                        } label: {
                            HStack {
                                Image(systemName: goalIds.contains(goal.id) ? "checkmark.circle.fill" : "circle")
                                Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Use local suggestions") {
                        goalIds.formUnion(GoalAttributionSuggester.suggestedGoalIds(
                            for: suggestionText, goals: goals.activeGoals))
                    }
                    .foregroundStyle(StrandPalette.accent)
                }
                if editingId != nil {
                    Section {
                        Button("Delete action", role: .destructive) {
                            if let editingId { store.remove(editingId) }
                            onSave(); dismiss()
                        }
                    }
                }
            }
            .navigationTitle(editingId == nil ? "New daily action" : "Edit daily action")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var suggestionText: String { kind == .workout ? workout : (kind == .steps ? "steps walking" : title) }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !goalIds.isEmpty && (daily || !weekdays.isEmpty)
            && (kind != .workout || !workout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        guard let id = editingId, let action = store.actions.first(where: { $0.id == id }) else { return }
        title = action.title
        goalIds = Set(action.goalIds)
        switch action.requirement {
        case .steps(let minimum): kind = .steps; steps = minimum
        case .manual: kind = .manual
        case .workout(let sports, let minutes):
            kind = .workout; workout = sports.joined(separator: ", ")
            hasMinimum = minutes != nil; minimumMinutes = minutes ?? 20
        }
        switch action.schedule {
        case .daily: daily = true
        case .weekdays(let values): daily = false; weekdays = Set(values)
        }
    }

    private func save() {
        let requirement: GoalAction.Requirement
        switch kind {
        case .steps: requirement = .steps(minimum: steps)
        case .manual: requirement = .manual
        case .workout:
            let sports = workout.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            requirement = .workout(sports: sports, minimumMinutes: hasMinimum ? minimumMinutes : nil)
        }
        let existing = editingId.flatMap { id in store.actions.first { $0.id == id } }
        store.upsert(GoalAction(id: existing?.id ?? UUID(),
                               title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               requirement: requirement,
                               schedule: daily ? .daily : .weekdays(weekdays.sorted()),
                               goalIds: goals.activeGoals.map(\.id).filter { goalIds.contains($0) },
                               isActive: existing?.isActive ?? true,
                               createdAt: existing?.createdAt ?? Date()))
        onSave(); dismiss()
    }

    private func shortWeekday(_ value: Int) -> String {
        let names = Calendar.current.shortStandaloneWeekdaySymbols
        return names.indices.contains(value - 1) ? String(names[value - 1].prefix(2)) : "\(value)"
    }
}
