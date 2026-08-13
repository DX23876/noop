import SwiftUI
import StrandDesign

struct CoachGoalSetupReviewView: View {
    let proposalId: UUID
    var onFinish: () -> Void = {}

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var proposals = CoachGoalSetupProposalStore.shared
    @ObservedObject private var goals = CoachGoalStore.shared
    @ObservedObject private var actions = GoalActionStore.shared
    @ObservedObject private var tracking = GoalTrackingStore.shared

    @State private var goalDraft: CoachGoalSetupProposal.GoalDraft?
    @State private var routines: [CoachGoalSetupProposal.RoutineDraft] = []
    @State private var selectedRoutineIds: Set<UUID> = []
    @State private var includeGoal = true
    @State private var rationale = ""
    @State private var editingRoutine: UUID?
    @State private var replaceCandidateId: UUID?
    @State private var showReplaceConfirm = false
    @State private var showRiskReason = false
    @State private var riskReason = ""
    @State private var errorMessage: String?
    @State private var loaded = false

    private var safety: GoalSafetyGate.Assessment? {
        goalDraft.map { GoalSafetyGate.assess(goal: $0.goal, bodyWeightKg: ProfileStore().weightKg) }
    }

    private var volume: GoalVolumeGate.Assessment? {
        goalDraft.map { GoalVolumeGate.assess(draft: $0.goal, against: goals.activeGoals,
                                              excludingId: $0.editingId) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !rationale.isEmpty {
                    Section("Coach's reasoning") { Text(rationale).foregroundStyle(StrandPalette.textSecondary) }
                }
                if goalDraft != nil { goalSection }
                if !routines.isEmpty { routinesSection }
                Section {
                    Text("Nothing here is active until you confirm. Goal outcomes remain separate from routine completion.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Section {
                    Button("Decline draft", role: .destructive, action: decline)
                }
            }
            .navigationTitle("Review goal & routines")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply selection", action: attemptApply).disabled(!hasSelection)
                }
            }
            .onAppear(perform: load)
            .sheet(item: editingRoutineBinding) { id in
                if let draft = routines.first(where: { $0.id == id.id }) {
                    CoachRoutineDraftEditor(draft: draft, availableGoals: availableGoals) { changed in
                        if let index = routines.firstIndex(where: { $0.id == changed.id }) {
                            routines[index] = changed
                        }
                    }
                }
            }
            .confirmationDialog("Replace your existing goal?", isPresented: $showReplaceConfirm,
                                titleVisibility: .visible) {
                Button("Replace it") { proceedPastLimits() }
                Button("Cancel", role: .cancel) { replaceCandidateId = nil }
            } message: {
                Text("A goal of this type is already active. Replacing it closes the old goal but keeps its history.")
            }
            .alert("Why this pace?", isPresented: $showRiskReason) {
                TextField("e.g. medical supervision", text: $riskReason)
                Button("Cancel", role: .cancel) {}
                Button("Apply anyway") { applySelection(acknowledgingRisk: true) }
            } message: {
                Text("This pace is faster than usually recommended. Add your reason before applying the goal.")
            }
            .alert("Can't apply this draft", isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Please review the draft.") }
        }
    }

    @ViewBuilder
    private var goalSection: some View {
        Section("Goal") {
            Toggle(isOn: Binding(get: { includeGoal }, set: { value in
                includeGoal = value
                if !value {
                    for routine in routines where onlySupportsSetupGoal(routine) {
                        selectedRoutineIds.remove(routine.id)
                    }
                }
            })) {
                Text(goalDraft?.operation == .update ? "Apply goal changes" : "Create this goal")
            }
            Picker("Type", selection: goalKindBinding) {
                ForEach(CoachGoal.Kind.allCases) { Text($0.label.localizedCatalogValue).tag($0) }
            }
            TextField("Goal title", text: goalTitleBinding)
            if goalDraft?.goal.kind.isQuantified == true {
                TextField("Starting value", text: goalNumberBinding(\.baseline))
                TextField("Target", text: goalNumberBinding(\.target))
                if let evidence = goalDraft?.baselineEvidence {
                    Text("Local baseline: \(evidence.value.formatted()) · \(evidence.source)")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Toggle("Target date", isOn: hasTargetDateBinding)
            if goalDraft?.goal.targetDate != nil {
                DatePicker("Date", selection: goalDateBinding, displayedComponents: .date)
            }
            DisclosureGroup("Why it matters") {
                ForEach(CoachGoal.MotivationTag.allCases) { tag in
                    Button { toggleTag(tag) } label: {
                        HStack {
                            Image(systemName: goalDraft?.goal.motivationTags.contains(tag) == true
                                  ? "checkmark.circle.fill" : "circle")
                            Text(tag.label.localizedCatalogValue)
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            }
            if let warning = safety?.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
            if let warning = volume?.warning {
                Label(warning, systemImage: "calendar.badge.exclamationmark")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
        }
        .opacity(includeGoal ? 1 : 0.6)
    }

    private var routinesSection: some View {
        Section("Routines") {
            ForEach(routines) { routine in
                let unavailable = !includeGoal && onlySupportsSetupGoal(routine)
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        if selectedRoutineIds.contains(routine.id) { selectedRoutineIds.remove(routine.id) }
                        else { selectedRoutineIds.insert(routine.id) }
                    } label: {
                        Image(systemName: selectedRoutineIds.contains(routine.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedRoutineIds.contains(routine.id)
                                             ? StrandPalette.accent : StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain).disabled(unavailable)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routine.action.title).font(StrandFont.footnote)
                        Text(routine.action.requirement.label.localizedCatalogValue)
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(linkedGoalNames(routine.action.goalIds).joined(separator: " · "))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        if unavailable {
                            Text("Select the setup goal or link another active goal.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                        }
                    }
                    Spacer()
                    Button("Edit") { editingRoutine = routine.id }.buttonStyle(.plain)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    private var availableGoals: [CoachGoal] {
        var values = goals.activeGoals
        if let setup = goalDraft?.goal, !values.contains(where: { $0.id == setup.id }) { values.insert(setup, at: 0) }
        return values
    }

    private var hasSelection: Bool { (includeGoal && goalDraft != nil) || !selectedRoutineIds.isEmpty }

    private func load() {
        guard !loaded else { return }; loaded = true
        guard let proposal = proposals.proposal(id: proposalId), proposal.status == .proposed else {
            errorMessage = "This draft is no longer waiting for review."
            return
        }
        goalDraft = proposal.goal
        routines = proposal.routines
        selectedRoutineIds = Set(proposal.routines.map(\.id))
        includeGoal = proposal.goal != nil
        rationale = proposal.rationale
    }

    private func attemptApply() {
        guard hasSelection else { return }
        for routine in routines where selectedRoutineIds.contains(routine.id) {
            if routine.operation == .update,
               (routine.editingId == nil
                || !actions.actions.contains(where: { $0.id == routine.editingId })) {
                errorMessage = "A routine this draft wanted to update no longer exists."
                return
            }
            let remaining = effectiveGoalIds(for: routine)
            if remaining.isEmpty {
                errorMessage = "Every selected routine must support at least one goal."
                return
            }
        }
        guard includeGoal, let draft = goalDraft else { applySelection(acknowledgingRisk: false); return }
        if let editingId = draft.editingId,
           goals.goal(id: editingId) == nil {
            errorMessage = "The goal this draft wanted to update no longer exists."
            return
        }
        if let limit = goals.canAdd(kind: draft.goal.kind, replacing: draft.editingId) {
            switch limit {
            case .kindAlreadyActive(let id):
                replaceCandidateId = id; showReplaceConfirm = true
            case .tooManyActive:
                errorMessage = "You already have \(CoachGoalStore.maxActiveGoals) active goals. Close or set one aside first."
            }
            return
        }
        proceedPastLimits()
    }

    private func proceedPastLimits() {
        let existingAck: CoachGoal.RiskAcknowledgement?
        if let editingId = goalDraft?.editingId {
            existingAck = goals.goal(id: editingId)?.acknowledgedRisk
        } else {
            existingAck = nil
        }
        if safety?.requiresReason == true && existingAck == nil { showRiskReason = true }
        else { applySelection(acknowledgingRisk: false) }
    }

    private func applySelection(acknowledgingRisk: Bool) {
        let ack = acknowledgingRisk
            ? CoachGoalRisk.acknowledgement(verdict: safety?.verdict.rawValue ?? "veryAggressive",
                                            reason: riskReason) : nil
        let clear = !acknowledgingRisk && (safety?.verdict == .ok || safety?.verdict == .notApplicable)
        let selection = CoachGoalSetupApplier.Selection(
            goal: goalDraft, includeGoal: includeGoal, routines: routines,
            selectedRoutineIds: selectedRoutineIds, replacingGoalId: replaceCandidateId,
            acknowledgedRisk: ack, clearStaleAcknowledgement: clear)
        if let error = CoachGoalSetupApplier.apply(
            proposalId: proposalId, selection: selection, proposalStore: proposals,
            goalStore: goals, actionStore: actions) {
            errorMessage = error.localizedDescription
            return
        }
        Task { await tracking.refresh(repo: repo) }
        onFinish(); dismiss()
    }

    private func decline() {
        proposals.decide(proposalId, as: .declined)
        onFinish(); dismiss()
    }

    private func effectiveGoalIds(for routine: CoachGoalSetupProposal.RoutineDraft) -> [UUID] {
        guard !includeGoal, let setupId = goalDraft?.goal.id else { return routine.action.goalIds }
        return routine.action.goalIds.filter { $0 != setupId }
    }

    private func onlySupportsSetupGoal(_ routine: CoachGoalSetupProposal.RoutineDraft) -> Bool {
        guard let id = goalDraft?.goal.id else { return false }
        return !routine.action.goalIds.isEmpty && routine.action.goalIds.allSatisfy { $0 == id }
    }

    private func linkedGoalNames(_ ids: [UUID]) -> [String] {
        ids.compactMap { id in
            availableGoals.first(where: { $0.id == id }).map { $0.title.isEmpty ? $0.kind.label : $0.title }
        }
    }

    private var goalKindBinding: Binding<CoachGoal.Kind> {
        Binding(get: { goalDraft?.goal.kind ?? .custom }, set: { value in
            goalDraft?.goal.kind = value; goalDraft?.baselineEvidence = nil
        })
    }
    private var goalTitleBinding: Binding<String> {
        Binding(get: { goalDraft?.goal.title ?? "" }, set: { goalDraft?.goal.title = $0 })
    }
    private func goalNumberBinding(_ keyPath: WritableKeyPath<CoachGoal, Double?>) -> Binding<String> {
        Binding(get: { goalDraft?.goal[keyPath: keyPath].map { String(format: "%g", $0) } ?? "" },
                set: { goalDraft?.goal[keyPath: keyPath] = Double($0.replacingOccurrences(of: ",", with: ".")) })
    }
    private var hasTargetDateBinding: Binding<Bool> {
        Binding(get: { goalDraft?.goal.targetDate != nil }, set: { value in
            goalDraft?.goal.targetDate = value ? (goalDraft?.goal.targetDate ?? Date().addingTimeInterval(60 * 86_400)) : nil
        })
    }
    private var goalDateBinding: Binding<Date> {
        Binding(get: { goalDraft?.goal.targetDate ?? Date() }, set: { goalDraft?.goal.targetDate = $0 })
    }
    private func toggleTag(_ tag: CoachGoal.MotivationTag) {
        guard var values = goalDraft?.goal.motivationTags else { return }
        if let index = values.firstIndex(of: tag) { values.remove(at: index) } else { values.append(tag) }
        goalDraft?.goal.motivationTags = CoachGoal.MotivationTag.allCases.filter { values.contains($0) }
    }
    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
    private var editingRoutineBinding: Binding<IdentifiedUUID?> {
        Binding(get: { editingRoutine.map(IdentifiedUUID.init) },
                set: { editingRoutine = $0?.id })
    }
}

private struct IdentifiedUUID: Identifiable {
    let id: UUID
    init(_ id: UUID) { self.id = id }
}

private struct CoachRoutineDraftEditor: View {
    let draft: CoachGoalSetupProposal.RoutineDraft
    let availableGoals: [CoachGoal]
    let onSave: (CoachGoalSetupProposal.RoutineDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable, Identifiable {
        case steps, workout, manual
        var id: String { rawValue }
    }
    @State private var title: String
    @State private var kind: Kind
    @State private var steps: Int
    @State private var sports: String
    @State private var minutes: Int
    @State private var hasMinimum: Bool
    @State private var daily: Bool
    @State private var weekdays: Set<Int>
    @State private var goalIds: Set<UUID>

    init(draft: CoachGoalSetupProposal.RoutineDraft, availableGoals: [CoachGoal],
         onSave: @escaping (CoachGoalSetupProposal.RoutineDraft) -> Void) {
        self.draft = draft; self.availableGoals = availableGoals; self.onSave = onSave
        _title = State(initialValue: draft.action.title)
        switch draft.action.requirement {
        case .steps(let value):
            _kind = State(initialValue: .steps); _steps = State(initialValue: value)
            _sports = State(initialValue: "Walking"); _minutes = State(initialValue: 20)
            _hasMinimum = State(initialValue: true)
        case .workout(let values, let value):
            _kind = State(initialValue: .workout); _steps = State(initialValue: 10_000)
            _sports = State(initialValue: values.joined(separator: ", "))
            _minutes = State(initialValue: value ?? 20); _hasMinimum = State(initialValue: value != nil)
        case .manual:
            _kind = State(initialValue: .manual); _steps = State(initialValue: 10_000)
            _sports = State(initialValue: "Walking"); _minutes = State(initialValue: 20)
            _hasMinimum = State(initialValue: true)
        }
        switch draft.action.schedule {
        case .daily: _daily = State(initialValue: true); _weekdays = State(initialValue: Set(1...7))
        case .weekdays(let values): _daily = State(initialValue: false); _weekdays = State(initialValue: Set(values))
        }
        _goalIds = State(initialValue: Set(draft.action.goalIds))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine") {
                    TextField("Name", text: $title)
                    Picker("Type", selection: $kind) {
                        Text("Steps").tag(Kind.steps); Text("Workout").tag(Kind.workout); Text("Manual").tag(Kind.manual)
                    }.pickerStyle(.segmented)
                    if kind == .steps {
                        Stepper("\(steps.formatted()) steps", value: $steps, in: 1_000...50_000, step: 500)
                    } else if kind == .workout {
                        TextField("Activities", text: $sports)
                        Toggle("Minimum duration", isOn: $hasMinimum)
                        if hasMinimum { Stepper("\(minutes) minutes", value: $minutes, in: 5...240, step: 5) }
                    }
                }
                Section("Schedule") {
                    Toggle("Every day", isOn: $daily)
                    if !daily {
                        HStack {
                            ForEach(1...7, id: \.self) { day in
                                Button(shortWeekday(day)) {
                                    if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                                }.buttonStyle(.bordered).tint(weekdays.contains(day) ? StrandPalette.accent : .secondary)
                            }
                        }
                    }
                }
                Section("Supports goals") {
                    ForEach(availableGoals) { goal in
                        Button {
                            if goalIds.contains(goal.id) { goalIds.remove(goal.id) } else { goalIds.insert(goal.id) }
                        } label: {
                            HStack {
                                Image(systemName: goalIds.contains(goal.id) ? "checkmark.circle.fill" : "circle")
                                Text(goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title)
                                Spacer()
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Edit routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !goalIds.isEmpty
            && (daily || !weekdays.isEmpty)
            && (kind != .workout || !sports.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func save() {
        var changed = draft
        changed.action.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .steps: changed.action.requirement = .steps(minimum: steps)
        case .manual: changed.action.requirement = .manual
        case .workout:
            changed.action.requirement = .workout(
                sports: sports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }, minimumMinutes: hasMinimum ? minutes : nil)
        }
        changed.action.schedule = daily ? .daily : .weekdays(weekdays.sorted())
        changed.action.goalIds = availableGoals.map(\.id).filter { goalIds.contains($0) }
        onSave(changed); dismiss()
    }
    private func shortWeekday(_ value: Int) -> String {
        let names = Calendar.current.shortStandaloneWeekdaySymbols
        return names.indices.contains(value - 1) ? String(names[value - 1].prefix(2)) : "\(value)"
    }
}
