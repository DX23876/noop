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

/// A plan to open after it was saved, by id. The page reads the plan from the model, so it shows
/// the stored plan rather than a copy taken at the moment it was written.
struct OpenedProgram: Identifiable {
    let id: UUID
}

extension TrainingProgram {
    /// What this plan is called on screen. The plan the migration made has no name, because a store
    /// cannot write one in the wearer's language, so the default lives here, in one place: two
    /// screens inventing their own would name the same plan differently.
    var displayName: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "My plan") : title
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
        // The name field starts on the name the plan is shown under, so the unnamed plan the
        // migration made opens with one rather than with an empty field and Save switched off. A
        // wearer starting a plan of their own types over it.
        var named = program
        named.title = program.displayName
        _program = State(initialValue: named)
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
                runningBlockCard
                targetsCard
                if !routines.isEmpty {
                    PlanReviewCard(review: model.review(of: current, routines: routines),
                                   routineTitles: Dictionary(routines.map { ($0.id, $0.title) },
                                                             uniquingKeysWith: { first, _ in first }))
                }
                routinesCard
                if !finishedRuns.isEmpty { historyCard }
                actionsCard
            }
            .padding(NoopMetrics.screenPadding)
        }
        .forgeScreenBackground()
        .navigationTitle(Text(current.displayName))
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
                    // Hidden unless the coach is switched on, configured and allowed these purposes.
                    if let coachContext { CoachCardButton(context: coachContext) }
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

    /// The next lighter week of this block, read from the same rule the state itself uses, and never
    /// past the block's last week: widening the search to reach the current week announced a week 9
    /// of an 8 week block, which is a promise the block has no way of keeping.
    private func nextDeloadWeek(after state: TrainingBlockState.State) -> Int? {
        guard let block = current.block, state.week < block.weeks else { return nil }
        return ((state.week + 1)...block.weeks).first {
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

    /// A run's figures, worked out from the workout log every time they are shown rather than stored,
    /// so this page cannot claim something the log does not say.
    private func report(_ run: TrainingBlockRun) -> BlockReport {
        BlockReport.make(run: run, workouts: model.workouts, exercises: model.exerciseById,
                         sessionsPerWeek: current.targets.sessionsPerWeek,
                         today: Repository.localDayKey(Date()))
    }

    /// The block being trained right now, with what has been done in it so far.
    @ViewBuilder private var runningBlockCard: some View {
        if let run = runs.first(where: { $0.endedOn == nil }) {
            let report = report(run)
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("This block so far").font(StrandFont.headline)
                    figures(report)
                }
            }
        }
    }

    private func figures(_ report: BlockReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let planned = report.plannedSessions {
                Text("\(report.doneSessions) of \(planned) sessions")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("\(report.doneSessions) sessions")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            Text("\(report.workSets) work sets")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            if report.loadKg > 0 {
                Text("\(TrainingPreferences.formattedVolume(report.loadKg)) moved")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            if report.unpricedWorkSets > 0 {
                Text("\(report.unpricedWorkSets) sets carried no weight to count.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Earlier blocks", overline: "History")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(Array(finishedRuns.reversed().enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Divider().overlay(StrandPalette.hairline) }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(run.startedOn) to \(run.endedOn ?? "")")
                                    .font(StrandFont.subhead.weight(.semibold))
                                Spacer()
                                Text(run.outcome == .finished
                                     ? String(localized: "Finished") : String(localized: "Stopped early"))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            figures(report(run))
                            if let line = comparisonLine(at: index) {
                                Text(line).font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// How a finished block compared with the one before it, in the figures the log holds.
    private func comparisonLine(at index: Int) -> String? {
        let newestFirst = Array(finishedRuns.reversed())
        guard newestFirst.indices.contains(index), newestFirst.indices.contains(index + 1) else { return nil }
        let delta = BlockReport.compare(previous: report(newestFirst[index + 1]),
                                        current: report(newestFirst[index]))
        var parts: [String] = []
        if delta.workSets != 0 {
            parts.append(delta.workSets > 0
                         ? String(localized: "\(delta.workSets) work sets more than the block before")
                         : String(localized: "\(-delta.workSets) work sets fewer than the block before"))
        }
        if abs(delta.loadKg) >= 1 {
            parts.append(delta.loadKg > 0
                         ? String(localized: "\(TrainingPreferences.formattedVolume(delta.loadKg)) more moved")
                         : String(localized: "\(TrainingPreferences.formattedVolume(-delta.loadKg)) less moved"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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

    /// What the coach reads about this plan: the same figures the page shows, never anything derived
    /// again for the coach alone. It comments; the wearer decides and nothing is written by it.
    private var coachContext: CoachCardContext? {
        guard !routines.isEmpty else { return nil }
        let review = model.review(of: current, routines: routines)
        let week = review.weeklySetsByRegion
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { "\(PlanReviewCard.regionName($0.key)) \($0.value.formatted(.number.precision(.fractionLength(0...1))))" }
            .joined(separator: ", ")
        let minutes = review.sessionMinutes.values.sorted()
        var lines = [String(localized: "Plan: \(current.displayName). Sessions a week: \(review.weeklySessionCount). Sets a week by region: \(week).")]
        if let low = minutes.first, let high = minutes.last {
            lines.append(String(localized: "Minutes a session: \(low) to \(high)."))
        }
        if let state = blockState {
            lines.append(state.isFinished
                         ? String(localized: "Its block has finished.")
                         : String(localized: "Block week \(state.week) of \(state.weeks)."))
        }
        return CoachCardContext(
            title: String(localized: "This plan"), summary: lines.joined(separator: " "),
            suggestions: [
                String(localized: "Does this plan fit what I have been training lately?"),
                String(localized: "What would you change about this plan?"),
                String(localized: "What should the next block look like?")
            ],
            requiredPurposes: [.planning, .workouts])
    }

    private var kindTitle: String {
        switch current.kind {
        case .strength: String(localized: "Strength")
        case .conditioning: String(localized: "Conditioning")
        case .mobility: String(localized: "Mobility")
        }
    }
}

/// Keeps a session that has been done as a routine, so it can be done again without typing it in.
///
/// One card, used by the summary a session finishes on and by the page of a session logged earlier.
/// Two copies would eventually offer two different things, and the wearer would not know which one
/// they had used. Nothing is saved until the button is pressed, and the routine goes into the plan
/// they pick, resting plans included.
struct KeepSessionAsRoutineCard: View {
    let workout: NativeWorkout
    var onSaved: () -> Void = {}
    @EnvironmentObject private var repo: Repository
    @State private var programs: [TrainingProgram] = []
    @State private var title = ""
    @State private var programId: UUID?
    @State private var state = State.offered

    private enum State { case offered, saving, saved, failed }

    var body: some View {
        if !workout.exercises.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("Keep this as a routine").font(StrandFont.headline)
                    Text("What you did becomes the prescription: the same exercises, sets, weights and repetitions. Sets you did not complete are left out.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    content
                }
            }
            .task {
                programs = await repo.nativeTrainingPrograms()
                if programId == nil {
                    programId = TrainingProgramActivation.active(.strength, in: programs)?.id
                        ?? programs.first?.id
                }
                if title.isEmpty { title = suggestedTitle }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .offered, .saving:
            TextField("Routine name", text: $title)
            #if os(iOS)
                .textFieldStyle(.roundedBorder)
            #endif
            if programs.count > 1 {
                Picker("Plan", selection: $programId) {
                    ForEach(programs) { program in
                        Text(program.displayName)
                            .tag(Optional(program.id))
                    }
                }
            }
            NoopButton("Save as routine", systemImage: "square.and.arrow.down",
                       kind: .secondary, fullWidth: true) { save() }
                .disabled(state == .saving || trimmedTitle.isEmpty || programs.isEmpty)
        case .saved:
            Label("Saved as a routine", systemImage: "checkmark.circle.fill")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.chargeColor)
        case .failed:
            Label("The routine could not be saved.", systemImage: "exclamationmark.triangle.fill")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.metricAmber)
            NoopButton("Try again", kind: .secondary, fullWidth: true) { save() }
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The session's own name with its date, which is what the wearer would have typed anyway.
    private var suggestedTitle: String {
        let date = Date(timeIntervalSince1970: TimeInterval(workout.startedAt))
        return "\(workout.title) \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func save() {
        guard let routine = RoutineFromWorkout.make(workout: workout, title: trimmedTitle,
                                                    programId: programId) else {
            state = .failed
            return
        }
        state = .saving
        Task {
            do {
                try await repo.saveNativeTrainingRoutine(routine)
                state = .saved
                onSaved()
            } catch {
                state = .failed
            }
        }
    }
}

/// What a plan amounts to in a week: sets per region, how long each session takes, and what stood
/// out about it.
///
/// Every sentence here is written from the figures `PlanReview` carried, so the screen says what was
/// compared rather than a verdict nobody can check. It warns and never blocks: a big step up can be
/// entirely deliberate, and the wearer decides.
struct PlanReviewCard: View {
    let review: PlanReview
    /// Routine titles, for a finding that names a session.
    let routineTitles: [UUID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("A week of this plan", overline: "Sets and time")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    ForEach(regions, id: \.0) { region, sets in
                        HStack {
                            Text(Self.regionName(region)).font(StrandFont.subhead)
                            Spacer()
                            Text("\(sets.formatted(.number.precision(.fractionLength(0...1)))) sets")
                                .font(StrandFont.subhead.monospacedDigit())
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    if !review.sessionMinutes.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                        HStack {
                            Text("Time a session").font(StrandFont.subhead)
                            Spacer()
                            Text(timeRange).font(StrandFont.subhead.monospacedDigit())
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
            if !review.findings.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                            Label {
                                Text(sentence(finding))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Regions with sets in them, most first, so the week reads at a glance.
    private var regions: [(TrainingBodyRegion, Double)] {
        review.weeklySetsByRegion
            .filter { $0.value > 0 }
            .sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .map { ($0.key, $0.value) }
    }

    private var timeRange: String {
        let minutes = review.sessionMinutes.values.sorted()
        guard let low = minutes.first, let high = minutes.last else { return "" }
        return low == high ? String(localized: "\(low) min")
                           : String(localized: "\(low) to \(high) min")
    }

    private func sentence(_ finding: PlanReview.Finding) -> String {
        switch finding {
        case .regionUntrained(let region):
            return String(localized: "Nothing for \(Self.regionName(region)) this week.")
        case .regionAboveUsual(let region, let weekly, let usual):
            return String(localized: "\(Self.regionName(region)): \(Int(weekly.rounded())) sets a week, against your own recent average of \(Int(usual.rounded())). That is a big step up, which is fine if you meant it.")
        case .heavyDaysBackToBack(let first, let second):
            return String(localized: "\(Self.dayName(first)) and \(Self.dayName(second)) both lean on your legs.")
        case .sessionLongerThanAsked(let id, let minutes, let asked):
            let title = routineTitles[id] ?? String(localized: "One session")
            return String(localized: "\(title) comes to about \(minutes) minutes, more than the \(asked) you asked for.")
        }
    }

    static func regionName(_ region: TrainingBodyRegion) -> String {
        switch region {
        case .chest: String(localized: "Chest")
        case .back: String(localized: "Back")
        case .shoulders: String(localized: "Shoulders")
        case .arms: String(localized: "Arms")
        case .core: String(localized: "Core")
        case .legs: String(localized: "Legs")
        case .other: String(localized: "Other")
        }
    }

    static func dayName(_ day: TrainingWeekday) -> String {
        // TrainingWeekday counts Monday as 1; the calendar's symbols start on Sunday.
        Calendar.autoupdatingCurrent.standaloneWeekdaySymbols[day.rawValue % 7]
    }
}
