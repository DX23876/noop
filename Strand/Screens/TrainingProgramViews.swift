import SwiftUI
import StrandDesign
import StrandTraining

/// What the routine editor was opened for. A routine that does not exist yet cannot be deleted and
/// has no days of its own, so the editor is told rather than left to guess from an empty title.
struct RoutineEditorRequest: Identifiable {
    let routine: TrainingRoutine
    let isNew: Bool

    var id: UUID { routine.id }

    static func existing(_ routine: TrainingRoutine) -> RoutineEditorRequest {
        RoutineEditorRequest(routine: routine, isNew: false)
    }

    /// A blank routine, already belonging to a plan so that saving it cannot leave it homeless.
    static func new(in programId: UUID?) -> RoutineEditorRequest {
        RoutineEditorRequest(routine: TrainingRoutine(title: "", programId: programId), isNew: true)
    }
}

/// A plan's own settings: what it is called, what kind it is, what it asks of a week, and whether it
/// runs for a fixed number of weeks.
///
/// Nothing here starts a plan. Taking one up is a separate, deliberate act on the plan's page, which
/// is what keeps a plan the wearer is still writing out of Today.
struct TrainingProgramEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var program: TrainingProgram
    let onSave: (TrainingProgram) -> Void
    @State private var hasBlock: Bool
    @State private var block: TrainingProgramBlock
    @State private var sessionsPerWeek: Int
    @State private var cardioMinutes: Int

    init(program: TrainingProgram, onSave: @escaping (TrainingProgram) -> Void) {
        _program = State(initialValue: program)
        self.onSave = onSave
        _hasBlock = State(initialValue: program.block != nil)
        _block = State(initialValue: program.block ?? TrainingProgramBlock())
        _sessionsPerWeek = State(initialValue: program.targets.sessionsPerWeek ?? 0)
        _cardioMinutes = State(initialValue: program.targets.cardioMinutesPerWeek ?? 0)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $program.title)
                Picker("Kind", selection: $program.kind) {
                    Text("Strength").tag(TrainingProgramKind.strength)
                    Text("Conditioning").tag(TrainingProgramKind.conditioning)
                    Text("Mobility").tag(TrainingProgramKind.mobility)
                }
                TextField("Notes", text: Binding(get: { program.notes ?? "" },
                                                  set: { program.notes = $0.isEmpty ? nil : $0 }),
                          axis: .vertical)
            } footer: {
                Text("One strength plan is followed at a time, and one plan of another kind can run beside it.")
            }

            Section {
                Stepper(sessionsPerWeek > 0
                        ? String(localized: "\(sessionsPerWeek) sessions a week")
                        : String(localized: "No session target"),
                        value: $sessionsPerWeek, in: 0...14)
                Stepper(cardioMinutes > 0
                        ? String(localized: "\(cardioMinutes) cardio minutes a week")
                        : String(localized: "No cardio target"),
                        value: $cardioMinutes, in: 0...1_200, step: 15)
            } header: {
                Text("What this plan asks of a week")
            } footer: {
                Text("These belong to the plan and leave with it.")
            }

            Section {
                Toggle("Run for a set number of weeks", isOn: $hasBlock)
                if hasBlock {
                    Stepper("\(block.weeks) weeks", value: $block.weeks, in: 2...52)
                    Toggle("Lighter final week", isOn: $block.deloadInFinalWeek)
                    Toggle("A lighter week every few weeks", isOn: Binding(
                        get: { block.deloadEveryWeeks != nil },
                        set: { block.deloadEveryWeeks = $0 ? 4 : nil }))
                    if let every = block.deloadEveryWeeks {
                        Stepper("Every \(every) weeks", value: Binding(
                            get: { every }, set: { block.deloadEveryWeeks = $0 }), in: 2...12)
                    }
                    Picker("Prescriptions over the block", selection: $block.progression) {
                        Text("Only what you earn").tag(BlockProgressionPolicy.none)
                        Text("A weight step each week").tag(BlockProgressionPolicy.weeklyLoad)
                        Text("A set more each week").tag(BlockProgressionPolicy.weeklyVolume)
                    }
                }
            } header: {
                Text("Block")
            } footer: {
                Text(hasBlock
                     ? String(localized: "A lighter week keeps \(Int((block.deloadFactor * 100).rounded())) % of the load. The plan reports when its last week is behind you, and changes nothing by itself.")
                     : String(localized: "Without a block the plan simply runs on."))
            }
        }
        .forgeListBackground()
        .navigationTitle(Text("Plan"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(program.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        program.targets = TrainingProgramTargets(
            sessionsPerWeek: sessionsPerWeek > 0 ? sessionsPerWeek : nil,
            cardioMinutesPerWeek: cardioMinutes > 0 ? cardioMinutes : nil,
            effortLow: program.targets.effortLow, effortHigh: program.targets.effortHigh)
        // A block that is already running keeps the day it started from, so editing the plan does
        // not put the wearer back in week one.
        var kept = block
        kept.startedOn = program.block?.startedOn
        program.block = hasBlock ? kept : nil
        onSave(program)
        dismiss()
    }
}

/// One plan's page: whether it is being followed, where it stands in its block, what it holds, and
/// the few things that can be done to it.
///
/// Taking a plan up happens here and nowhere else. That is what makes a prepared plan safe to write:
/// until this button is pressed it is not in Today, not in the week, and not in the quick start.
struct TrainingProgramDetailView: View {
    let program: TrainingProgram
    @ObservedObject var model: TrainingHubModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var routines: [TrainingRoutine] = []
    @State private var runs: [TrainingBlockRun] = []
    @State private var editing = false
    @State private var confirmingDelete = false

    /// The plan as the model holds it now, so activating or editing it updates this page.
    private var current: TrainingProgram { model.program(program.id) ?? program }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                stateCard
                if let state = blockState { blockCard(state) }
                targetsCard
                routinesCard
                if !finishedRuns.isEmpty { historyCard }
                actionsCard
            }
            .padding(NoopMetrics.screenPadding)
        }
        .forgeScreenBackground()
        .navigationTitle(Text(current.title))
        .task(id: model.programs.count) { await reload() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                TrainingProgramEditorView(program: current) { updated in
                    Task { await model.saveProgram(updated, repo: repo) }
                }
            }
        }
        .confirmationDialog("Delete this plan?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete plan", role: .destructive) {
                Task { await model.deleteProgram(current.id, repo: repo); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its routines and its week go with it. Workouts you have logged stay in your history.")
        }
    }

    private func reload() async {
        routines = await model.routines(ofProgram: program.id, repo: repo)
        runs = await repo.nativeTrainingBlockRuns(programId: program.id)
    }

    // MARK: Cards

    private var stateCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Text(kindTitle).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if current.isActive {
                        Label("Being followed", systemImage: "checkmark.circle.fill")
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
                Text(current.isActive
                     ? String(localized: "This plan is in your week, on Today and in the quick start.")
                     : String(localized: "Resting. Nothing from this plan can be started until you take it up."))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                if current.isActive {
                    Button("Let this plan rest") {
                        Task { await model.deactivateProgram(current.id, repo: repo) }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await model.activateProgram(current.id, repo: repo) }
                    } label: {
                        Label("Follow this plan", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, NoopMetrics.space3)
                    }
                    .buttonStyle(.noopProminent).tint(StrandPalette.accent)
                    if let replaced = model.programs.first(where: {
                        $0.isActive && $0.kind == current.kind && $0.id != current.id
                    }) {
                        Text("\(replaced.title) goes back to resting.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var blockState: TrainingBlockState.State? {
        TrainingBlockState.resolve(block: current.block, today: Repository.localDayKey(Date()))
    }

    private func blockCard(_ state: TrainingBlockState.State) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(state.isFinished
                     ? String(localized: "Block finished")
                     : String(localized: "Week \(state.week) of \(state.weeks)"))
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                if state.isFinished {
                    Text("Nothing has changed by itself. Run it again, build the next one, or follow another plan.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else if state.isDeload {
                    Text("A lighter week: this week's sessions are prescribed at \(Int((state.loadFactor * 100).rounded())) % of their load.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else if let next = nextDeloadWeek(after: state) {
                    Text("Lighter week in week \(next).")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    /// The next lighter week of this block, read from the same rule the state itself uses.
    private func nextDeloadWeek(after state: TrainingBlockState.State) -> Int? {
        guard let block = current.block else { return nil }
        return ((state.week + 1)...max(state.week + 1, block.weeks)).first {
            TrainingBlockState.isDeloadWeek($0, block: block)
        }
    }

    @ViewBuilder private var targetsCard: some View {
        if !current.targets.isEmpty || current.notes != nil {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if let notes = current.notes {
                        Text(notes).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    if let sessions = current.targets.sessionsPerWeek {
                        Label("\(sessions) sessions a week", systemImage: "calendar")
                            .font(StrandFont.subhead)
                    }
                    if let minutes = current.targets.cardioMinutesPerWeek {
                        Label("\(minutes) cardio minutes a week", systemImage: "figure.run")
                            .font(StrandFont.subhead)
                    }
                }
            }
        }
    }

    private var routinesCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Routines", overline: "In this plan")
            NoopCard {
                if routines.isEmpty {
                    Text("No routines yet.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        ForEach(routines) { routine in
                            HStack {
                                Text(routine.title).font(StrandFont.subhead.weight(.semibold))
                                Spacer()
                                Text(weekdayLabel(routine))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func weekdayLabel(_ routine: TrainingRoutine) -> String {
        let days = RoutineEditing.weekdays(of: routine.id, in: current.schedule)
        guard !days.isEmpty else { return String(localized: "No day") }
        let symbols = Calendar.autoupdatingCurrent.shortStandaloneWeekdaySymbols
        return days.sorted { $0.rawValue < $1.rawValue }
            .map { String(symbols[$0.rawValue % 7].prefix(2)) }
            .joined(separator: " ")
    }

    private var finishedRuns: [TrainingBlockRun] { runs.filter { $0.endedOn != nil } }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Earlier blocks", overline: "History")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    ForEach(finishedRuns.reversed()) { run in
                        HStack {
                            Text("\(run.startedOn) to \(run.endedOn ?? "")")
                                .font(StrandFont.subhead)
                            Spacer()
                            Text(run.outcome == .finished
                                 ? String(localized: "Finished") : String(localized: "Stopped early"))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var actionsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Button("Edit plan") { editing = true }
                Divider().overlay(StrandPalette.hairline)
                Button("Duplicate plan") {
                    Task { await model.duplicateProgram(current, repo: repo) }
                }
                Divider().overlay(StrandPalette.hairline)
                Button("Delete plan", role: .destructive) { confirmingDelete = true }
            }
        }
    }

    private var kindTitle: String {
        switch current.kind {
        case .strength: String(localized: "Strength")
        case .conditioning: String(localized: "Conditioning")
        case .mobility: String(localized: "Mobility")
        }
    }
}
