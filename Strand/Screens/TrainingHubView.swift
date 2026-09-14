import SwiftUI
import StrandDesign
import StrandTraining
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Native training home inspired by OpenGym's useful structure while keeping NOOP's own visual system,
/// source provenance, analytics and data model. No OpenGym source, strings or assets are included.
struct TrainingHubView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = TrainingHubModel()
    @State private var selectedTrackerId: String?
    @State private var showingStarterPlans = false
    @State private var showingSchedule = false
    @State private var showingLibrary = false
    @State private var showingPlanImporter = false
    @State private var showingHistoryImporter = false
    @State private var showingPastWorkout = false
    @State private var editingDay: TrainingDaySelection?
    @State private var editingRoutine: TrainingRoutine?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                header
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    startCard
                    weekCard
                    routinesCard
                    TrainingActivityHeatmap(workouts: model.workouts)
                    TrainingMuscleMapCard(workouts: model.workouts, exercises: model.exercises)
                    analysisCard
                    recentCard
                }
                DemoScrollBottomAnchor()
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Training"))
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .sheet(item: $model.draft) { draft in
            NativeWorkoutLoggerView(draft: draft, exercises: model.exercises,
                                    history: model.workouts, repo: repo) {
                Task { await model.workoutFinished(repo: repo) }
            }
        }
        .sheet(isPresented: $showingStarterPlans) {
            NavigationStack { starterPlans }
        }
        .sheet(isPresented: $showingSchedule) {
            NavigationStack {
                TrainingScheduleEditorView(plan: model.plan) { schedule in
                    Task { await model.saveSchedule(schedule, repo: repo) }
                }
            }
        }
        .sheet(isPresented: $showingLibrary) {
            NavigationStack {
                TrainingExerciseLibraryView(exercises: model.exercises) { exercise in
                    Task { await model.saveExercise(exercise, repo: repo) }
                }
            }
        }
        .sheet(item: $editingDay) { selection in
            NavigationStack {
                TrainingDayEditorView(date: selection.date, plan: model.plan,
                    onSave: { override in Task { await model.saveOverride(override, repo: repo) } },
                    onReset: { day in Task { await model.clearOverride(day: day, repo: repo) } })
            }
        }
        .sheet(item: $editingRoutine) { routine in
            NavigationStack {
                RoutineEditorView(routine: routine, exercises: model.exercises,
                    onSave: { updated in Task { await model.saveRoutine(updated, repo: repo) } },
                    onDelete: { id in Task { await model.deleteRoutine(id, repo: repo) } })
            }
        }
        .sheet(isPresented: $showingPastWorkout) {
            NavigationStack {
                PastWorkoutStartView(routines: model.plan.routines, trackers: model.trackers) {
                    routines, tracker, date, duration in
                    showingPastWorkout = false
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        await model.start(routines: routines, tracker: tracker, repo: repo,
                                          date: date, pastDurationS: duration)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showingPlanImporter, allowedContentTypes: [.json]) { result in
            consume(result) { data in await model.importPlan(data, repo: repo) }
        }
        .fileImporter(isPresented: $showingHistoryImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            consume(result) { data in await model.importHistory(data, repo: repo) }
        }
        .alert("Training", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader("Training", overline: "Plan and log")
            Spacer()
            if let coachContext {
                CoachCardButton(context: coachContext)
            }
            Button { start([], tracker: selectedTracker) } label: {
                Label("Freestyle", systemImage: "plus.circle.fill")
                    .font(StrandFont.subhead.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
        }
    }

    private var startCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.draft == nil ? "Ready to train?" : "Workout in progress")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(model.draft == nil
                            ? String(localized: "Log every set locally and keep its source.")
                            : model.draft?.title ?? "")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "dumbbell.fill")
                        .font(.title2).foregroundStyle(StrandPalette.accent)
                }

                trackerPicker

                if let draft = model.draft {
                    Button { model.draft = draft } label: {
                        Label("Resume workout", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                } else if !model.routines(on: Date()).isEmpty {
                    let today = model.routines(on: Date())
                    Button { start(today, tracker: selectedTracker) } label: {
                        Label("Start today's plan", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                } else {
                    HStack(spacing: 10) {
                        Button { start([], tracker: selectedTracker) } label: {
                            Label("Freestyle", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                        Button { showingStarterPlans = true } label: {
                            Text("Choose plan").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder private var trackerPicker: some View {
        if model.trackers.isEmpty {
            Label("No tracker assigned — you can still log every set.", systemImage: "waveform.slash")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        } else {
            HStack {
                Label("Tracker for this workout", systemImage: "sensor.tag.radiowaves.forward.fill")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Picker("Tracker", selection: $selectedTrackerId) {
                    Text("None").tag(String?.none)
                    ForEach(model.trackers, id: \.trackerId) { tracker in
                        Text(tracker.model ?? tracker.manufacturer ?? "Tracker").tag(tracker.trackerId)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
        }
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                SectionHeader("This week", overline: "Schedule")
                Spacer()
                Button("Edit") { showingSchedule = true }
                    .font(StrandFont.subhead.weight(.semibold))
            }
            NoopCard {
                HStack(spacing: 7) {
                    ForEach(Array(weekDates.enumerated()), id: \.offset) { offset, date in
                        let routines = model.routines(on: date)
                        Button { editingDay = TrainingDaySelection(date: date) } label: {
                            VStack(spacing: 6) {
                                Text(date.formatted(.dateTime.weekday(.narrow)))
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                Text(date.formatted(.dateTime.day()))
                                    .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                                Circle().fill(routines.isEmpty ? StrandPalette.hairline : StrandPalette.accent)
                                    .frame(width: 6, height: 6)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Calendar.current.isDateInToday(date)
                                ? StrandPalette.accent.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)), \(routines.count) routines")
                    }
                }
            }
        }
    }

    private var routinesCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                SectionHeader("Routines", overline: "Your training")
                Spacer()
                Menu {
                    Button("Exercise library") { showingLibrary = true }
                    Button("Add routine") { showingStarterPlans = true }
                    Divider()
                    Button("Share training plan") { exportPlan() }
                    Button("Export plan as PDF") { exportPlanPDF() }
                    Button("Import training plan") { showingPlanImporter = true }
                    Button("Import FitNotes or Strong history") { showingHistoryImporter = true }
                    Button("Log past workout") { showingPastWorkout = true }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(StrandFont.subhead.weight(.semibold))
                }
            }
            if model.plan.routines.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Build a repeatable plan").font(StrandFont.headline)
                        Text("Start with a template, then change exercises, sets, rest and progression to fit you.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Button("Browse starter plans") { showingStarterPlans = true }
                            .buttonStyle(.bordered).tint(StrandPalette.accent)
                    }
                }
            } else {
                ForEach(model.plan.routines) { routine in
                    NoopCard {
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle.fill")
                                .foregroundStyle(StrandPalette.accent).font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(routine.title).font(StrandFont.headline)
                                Text("\(routine.exercises.count) exercises")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            Button { start([routine], tracker: selectedTracker) } label: {
                                Image(systemName: "play.fill")
                            }.buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                            Button { editingRoutine = routine } label: { Image(systemName: "slider.horizontal.3") }
                                .buttonStyle(.plain).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Understand your training", overline: "NOOP analysis")
            NoopCard {
                VStack(spacing: 0) {
                    NavigationLink { TrainingLoadView() } label: { analysisRow("Training Load", "Strength and cardio against your own baseline", "gauge.with.dots.needle.67percent") }
                    Divider().overlay(StrandPalette.hairline)
                    NavigationLink { StrengthView() } label: { analysisRow("Strength", "Records, progression, muscles and balance", "dumbbell.fill") }
                    Divider().overlay(StrandPalette.hairline)
                    NavigationLink { CardioView() } label: { analysisRow("Cardio", "Pace, distance, zones and cardio load", "figure.run") }
                }
            }
        }
    }

    private func analysisRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey,
                             _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 28).foregroundStyle(StrandPalette.metricCyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 11).contentShape(Rectangle())
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recent", overline: "Logged in NOOP")
            NoopCard {
                if model.workouts.isEmpty {
                    Text("Your completed workouts will appear here.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.workouts.prefix(5)) { workout in
                            NavigationLink { NativeWorkoutDetailView(workout: workout, exercises: model.exercises) } label: {
                              HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.title).font(StrandFont.subhead.weight(.semibold))
                                    Text("\(workout.exercises.count) exercises · \(workout.exercises.flatMap(\.sets).count) sets")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer()
                                Text(Date(timeIntervalSince1970: TimeInterval(workout.startedAt)), style: .date)
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                Image(systemName: "chevron.right").font(.caption2)
                                    .foregroundStyle(StrandPalette.textTertiary)
                              }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var starterPlans: some View {
        List {
            Section {
                ForEach(TrainingStarterCatalog.starterRoutines()) { routine in
                    Button {
                        Task {
                            await model.addStarter(routine, repo: repo)
                            showingStarterPlans = false
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(routine.title).font(.headline)
                            Text(routine.exercises.compactMap { model.exerciseById[$0.exerciseId]?.title }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("Templates are editable and stay on your device.")
            }
        }
        .navigationTitle(Text("Starter plans"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingStarterPlans = false } } }
    }

    private var selectedTracker: SessionTrackerAttribution? {
        guard let selectedTrackerId else { return nil }
        return model.trackers.first { $0.trackerId == selectedTrackerId }
    }

    private var coachContext: CoachCardContext? {
        guard !model.plan.routines.isEmpty else { return nil }
        let scheduled = TrainingWeekday.allCases.compactMap { weekday -> String? in
            let names = (model.plan.schedule[weekday] ?? []).compactMap { id in
                model.plan.routines.first { $0.id == id }?.title
            }
            guard !names.isEmpty else { return nil }
            return "\(weekday.title): \(names.joined(separator: " + "))"
        }
        let methods = Set(model.plan.routines.map { progressionName($0.defaultProgression.policy) })
            .sorted().joined(separator: ", ")
        let recent = model.workouts.filter {
            $0.startedAt >= Int(Date().timeIntervalSince1970) - 28 * 86_400
        }.count
        let summary = String(localized: "Routines: \(model.plan.routines.count). Schedule: \(scheduled.joined(separator: "; ")). Progression: \(methods). Completed in the past 28 days: \(recent).")
        return CoachCardContext(
            title: String(localized: "Training plan"), summary: summary,
            suggestions: [
                String(localized: "Review the balance of my training plan."),
                String(localized: "How should I adjust this plan to my recent recovery?"),
                String(localized: "Which muscle groups may be missing from this plan?")
            ])
    }

    private func progressionName(_ policy: ProgressionPolicy) -> String {
        switch policy {
        case .off: return String(localized: "Manual")
        case .linear: return String(localized: "Linear")
        case .doubleProgression: return String(localized: "Double progression")
        case .greyskullLP: return "Greyskull LP"
        case .time: return String(localized: "Time progression")
        }
    }

    private var weekDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysFromStart: Int
        switch model.plan.weekStartsOn {
        case .monday: daysFromStart = (weekday + 5) % 7
        case .sunday: daysFromStart = weekday - 1
        }
        let start = calendar.date(byAdding: .day, value: -daysFromStart, to: today) ?? today
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func start(_ routines: [TrainingRoutine], tracker: SessionTrackerAttribution?) {
        Task { await model.start(routines: routines, tracker: tracker, repo: repo) }
    }

    private func exportPlan() {
        guard let data = try? model.planArchiveData(), let text = String(data: data, encoding: .utf8) else {
            model.errorMessage = String(localized: "The training plan could not be shared.")
            return
        }
        FileExport.exportText(text, suggestedName: FileExport.timestampedName("noop-training-plan", ext: "json"))
    }

    @MainActor
    private func exportPlanPDF() {
        let page = TrainingPlanPDFPage(plan: model.plan, exercises: model.exercises,
                                       generatedOn: Date().formatted(date: .long, time: .omitted))
        TrendsReportRenderer.exportPDF(
            page: page,
            suggestedName: FileExport.timestampedName("noop-training-plan", ext: "pdf"))
    }

    private func consume(_ result: Result<URL, Error>, action: @escaping (Data) async -> Void) {
        guard case .success(let url) = result else {
            model.errorMessage = String(localized: "The selected file could not be opened.")
            return
        }
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.errorMessage = String(localized: "The selected file could not be opened.")
                return
            }
            await action(data)
        }
    }
}

private struct TrainingDaySelection: Identifiable {
    let date: Date
    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}

private struct PastWorkoutStartView: View {
    @Environment(\.dismiss) private var dismiss
    let routines: [TrainingRoutine]
    let trackers: [SessionTrackerAttribution]
    let onStart: ([TrainingRoutine], SessionTrackerAttribution?, Date, Int) -> Void
    @State private var date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var durationMinutes = 60
    @State private var routineIds = Set<UUID>()
    @State private var trackerId: String?

    var body: some View {
        Form {
            Section("When") {
                DatePicker("Start", selection: $date, in: ...Date())
                Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 5...300, step: 5)
            }
            Section("Routines") {
                if routines.isEmpty {
                    Text("No routine selected. A freestyle entry will open.").foregroundStyle(.secondary)
                } else {
                    ForEach(routines) { routine in
                        Toggle(routine.title, isOn: Binding(get: { routineIds.contains(routine.id) }, set: { enabled in
                            if enabled { routineIds.insert(routine.id) } else { routineIds.remove(routine.id) }
                        }))
                    }
                }
            }
            Section("Tracker used for this workout") {
                Picker("Tracker", selection: $trackerId) {
                    Text("No tracker").tag(String?.none)
                    ForEach(trackers, id: \.trackerId) { tracker in
                        Text(tracker.model ?? tracker.manufacturer ?? String(localized: "Tracker"))
                            .tag(tracker.trackerId)
                    }
                }
                Text("Choose only the device worn for this session. NOOP does not average multiple trackers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text("Log past workout"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") {
                    let selected = routines.filter { routineIds.contains($0.id) }
                    let tracker = trackers.first { $0.trackerId == trackerId }
                    onStart(selected, tracker, date, durationMinutes * 60)
                }
            }
        }
    }
}

private struct NativeWorkoutDetailView: View {
    let workout: NativeWorkout
    let exercises: [TrainingExercise]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(workout.title).font(StrandFont.title1.weight(.bold))
                        HStack(spacing: 16) {
                            Label(Date(timeIntervalSince1970: TimeInterval(workout.startedAt))
                                .formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            Label(duration, systemImage: "clock")
                        }
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        if let note = workout.note, !note.isEmpty {
                            Text(note).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        HStack(spacing: 16) {
                            Label("\(workout.exercises.count) exercises", systemImage: "dumbbell")
                            Label("\(workingSets) working sets", systemImage: "checkmark.circle")
                            if let effort = workout.sessionRPE {
                                Label("RPE \(effort.formatted(.number.precision(.fractionLength(0...1))))",
                                      systemImage: "gauge.with.dots.needle.50percent")
                            }
                        }
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                ForEach(workout.exercises) { exercise in
                    let definition = exercises.first { $0.id == exercise.exerciseId }
                    NoopCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(definition?.title ?? exercise.exerciseId).font(StrandFont.headline)
                                    Text(definition?.primaryMuscleId?.replacingOccurrences(of: "_", with: " ").capitalized ?? "")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer()
                                if exercise.supersetId != nil {
                                    Label("Superset", systemImage: "link")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.metricCyan)
                                }
                            }
                            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                                HStack {
                                    Text(set.phase == .warmup ? "W" : "\(index + 1)")
                                        .font(StrandFont.caption.weight(.bold)).frame(width: 28)
                                    Text(setSummary(set, mode: definition?.mode ?? .weightReps,
                                                    unilateral: definition?.isUnilateral == true))
                                        .font(StrandFont.subhead.monospacedDigit())
                                    Spacer()
                                    if let effort = set.effort {
                                        Text("\(effort.scale == .rir ? "RIR" : "RPE") \(effort.value.formatted(.number.precision(.fractionLength(0...1))))")
                                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                    }
                                }
                                if index < exercise.sets.count - 1 { Divider().overlay(StrandPalette.hairline) }
                            }
                        }
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Data source").font(StrandFont.subhead.weight(.semibold))
                        Text(sourceText).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        if let tracker = workout.tracker {
                            Text("Tracker: \(tracker.model ?? tracker.manufacturer ?? String(localized: "Unknown"))")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Text("The workout logger and physiological tracker are stored separately. Only the selected tracker is attributed to this session.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                DemoScrollBottomAnchor()
            }.padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text("Workout details"))
    }

    private var workingSets: Int {
        workout.exercises.flatMap(\.sets).filter { $0.phase == .work && $0.isCompleted }.count
    }

    private var duration: String {
        let seconds = max(0, workout.endedAt - workout.startedAt)
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinute))
    }

    private var sourceText: String {
        switch workout.source {
        case .noopNative: return String(localized: "Logged in NOOP")
        case .hevyAPI: return "Hevy API"
        case .hevyCSV: return "Hevy CSV"
        case .liftosaur: return "Liftosaur"
        case .fitNotes: return "FitNotes"
        case .strong: return "Strong"
        case .imported: return String(localized: "Imported")
        }
    }

    private func setSummary(_ set: NativeWorkoutSet, mode: TrainingMeasurementMode,
                            unilateral: Bool) -> String {
        let reps = repsSummary(set, unilateral: unilateral)
        switch mode {
        case .weightReps:
            return "\(set.weightKg?.formatted(.number.precision(.fractionLength(0...1))) ?? "—") kg × \(reps)"
        case .weightedBodyweight:
            return "+\(set.weightKg?.formatted(.number.precision(.fractionLength(0...1))) ?? "—") kg × \(reps)"
        case .assistedBodyweight:
            return "−\(set.weightKg?.formatted(.number.precision(.fractionLength(0...1))) ?? "—") kg × \(reps)"
        case .bodyweightReps, .repetitions:
            return "\(reps) reps"
        case .duration:
            return Duration.seconds(set.durationS ?? 0).formatted(.time(pattern: .minuteSecond))
        case .distanceDuration:
            return "\(set.distanceM?.formatted(.number.precision(.fractionLength(0...1))) ?? "—") m · \(Duration.seconds(set.durationS ?? 0).formatted(.time(pattern: .minuteSecond)))"
        }
    }

    private func repsSummary(_ set: NativeWorkoutSet, unilateral: Bool) -> String {
        guard unilateral else { return set.reps.map(String.init) ?? "—" }
        let left = set.leftReps.map(String.init) ?? "—"
        let right = set.rightReps.map(String.init) ?? "—"
        return "L \(left) · R \(right)"
    }
}

private struct NativeWorkoutLoggerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: NativeWorkoutSessionModel
    let exercises: [TrainingExercise]
    let history: [NativeWorkout]
    let onFinish: () -> Void
    @State private var showingExercises = false
    @State private var exerciseQuery = ""
    @State private var plateRequest: TrainingPlateRequest?
    #if os(macOS)
    @State private var macActivity: NSObjectProtocol?
    #endif

    init(draft: WorkoutDraft, exercises: [TrainingExercise], history: [NativeWorkout], repo: Repository,
         onFinish: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativeWorkoutSessionModel(draft: draft, repo: repo))
        self.exercises = exercises
        self.history = history
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    sessionHeader
                    if let end = model.restEndsAt, end > Date() { restTimer(end) }
                    ForEach(Array(model.draft.exercises.enumerated()), id: \.element.id) { index, exercise in
                        exerciseCard(index, exercise)
                    }
                    Button { showingExercises = true } label: {
                        Label("Add exercise", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.bordered).tint(StrandPalette.accent)
                    finishCard
                }.padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(model.draft.title)
            .trainingInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $showingExercises) { exercisePicker }
            .sheet(item: $plateRequest) { request in
                NavigationStack { TrainingPlateCalculatorView(targetKg: request.targetKg) }
            }
            .alert("Workout", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
            #if os(iOS)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            #elseif os(macOS)
            .onAppear {
                macActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "Workout logging")
            }
            .onDisappear {
                if let macActivity { ProcessInfo.processInfo.endActivity(macActivity) }
                macActivity = nil
            }
            #endif
        }
    }

    private var sessionHeader: some View {
        NoopCard {
            HStack {
                Label {
                    Text(Date(timeIntervalSince1970: TimeInterval(model.draft.startedAt)), style: .time)
                } icon: {
                    Image(systemName: "clock.fill")
                }
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(model.draft.tracker?.model ?? String(localized: "No tracker"))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func restTimer(_ end: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(end.timeIntervalSince(context.date)))
            HStack {
                Label("Rest", systemImage: "timer").font(StrandFont.subhead.weight(.semibold))
                Spacer()
                Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .font(StrandFont.number(24)).monospacedDigit()
                Button("Skip") { model.skipRest() }.font(StrandFont.caption)
            }
            .padding().background(StrandPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func exerciseCard(_ exerciseIndex: Int, _ exercise: NativeWorkoutExercise) -> some View {
        let definition = exercises.first { $0.id == exercise.exerciseId }
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(definition?.title ?? exercise.exerciseId).font(StrandFont.headline)
                        Text(definition?.primaryMuscleId?.replacingOccurrences(of: "_", with: " ").capitalized ?? "")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Menu {
                        if definition?.mode == .weightReps {
                            Button("Plate calculator") {
                                plateRequest = TrainingPlateRequest(
                                    targetKg: exercise.sets.first(where: { $0.phase == .work })?.weightKg ?? 60)
                            }
                        }
                        if model.draft.exercises.indices.contains(exerciseIndex + 1) {
                            Button("Superset with next exercise") { model.supersetWithNext(exerciseIndex: exerciseIndex) }
                        }
                        Button("Remove", role: .destructive) { model.removeExercise(exercise.id) }
                    }
                         label: { Image(systemName: "ellipsis") }
                }
                if exercise.supersetId != nil {
                    Label("Superset", systemImage: "link")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.metricCyan)
                }
                if let previous = previousPerformance(for: exercise, mode: definition?.mode ?? .weightReps,
                                                      unilateral: definition?.isUnilateral == true) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        Label("Last time", systemImage: "clock.arrow.circlepath")
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.metricCyan)
                        Text(previous)
                            .font(StrandFont.caption.monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, NoopMetrics.space1)
                }
                setHeader(definition?.mode ?? .weightReps, unilateral: definition?.isUnilateral == true)
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { setIndex, set in
                    setRow(exerciseIndex, setIndex, set, mode: definition?.mode ?? .weightReps,
                           unilateral: definition?.isUnilateral == true)
                }
                Button { model.addSet(to: exercise.id) } label: { Label("Add set", systemImage: "plus") }
                    .font(StrandFont.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
            }
        }
    }

    private func previousPerformance(for exercise: NativeWorkoutExercise,
                                     mode: TrainingMeasurementMode,
                                     unilateral: Bool) -> String? {
        guard let priorWorkout = history.first(where: { workout in
            workout.exercises.contains { $0.exerciseId == exercise.exerciseId }
        }), let priorExercise = priorWorkout.exercises.first(where: {
            $0.exerciseId == exercise.exerciseId
        }) else { return nil }
        let sets = priorExercise.sets.filter { $0.phase == .work && $0.isCompleted }
        guard !sets.isEmpty else { return nil }
        let summaries = sets.prefix(4).map { previousSetSummary($0, mode: mode, unilateral: unilateral) }
        let date = Date(timeIntervalSince1970: TimeInterval(priorWorkout.startedAt))
            .formatted(date: .abbreviated, time: .omitted)
        return "\(date) · \(summaries.joined(separator: ", "))"
    }

    private func previousSetSummary(_ set: NativeWorkoutSet,
                                    mode: TrainingMeasurementMode,
                                    unilateral: Bool) -> String {
        let reps = unilateral
            ? "L \(set.leftReps.map(String.init) ?? "—") · R \(set.rightReps.map(String.init) ?? "—")"
            : set.reps.map(String.init) ?? "—"
        switch mode {
        case .weightReps:
            return "\(number(set.weightKg)) kg × \(reps)"
        case .weightedBodyweight:
            return "+\(number(set.weightKg)) kg × \(reps)"
        case .assistedBodyweight:
            return "−\(number(set.weightKg)) kg × \(reps)"
        case .bodyweightReps, .repetitions:
            return "\(reps) reps"
        case .duration:
            return durationText(set.durationS)
        case .distanceDuration:
            return "\(number(set.distanceM)) m · \(durationText(set.durationS))"
        }
    }

    private func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...2))) ?? "—"
    }

    private func setHeader(_ mode: TrainingMeasurementMode, unilateral: Bool) -> some View {
        HStack {
            Text("SET").frame(width: 36)
            switch mode {
            case .weightReps, .weightedBodyweight:
                Text("WEIGHT").frame(maxWidth: .infinity)
                repsHeader(unilateral: unilateral)
            case .assistedBodyweight:
                Text("ASSIST").frame(maxWidth: .infinity)
                repsHeader(unilateral: unilateral)
            case .bodyweightReps, .repetitions:
                repsHeader(unilateral: unilateral)
            case .duration:
                Text("TIME").frame(maxWidth: .infinity)
            case .distanceDuration:
                Text("DISTANCE").frame(maxWidth: .infinity); Text("TIME").frame(maxWidth: .infinity)
            }
            Text("EFFORT").frame(width: 50)
            Color.clear.frame(width: 30)
        }
        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
    }

    @ViewBuilder private func repsHeader(unilateral: Bool) -> some View {
        if unilateral {
            Text("LEFT").frame(maxWidth: .infinity)
            Text("RIGHT").frame(maxWidth: .infinity)
        } else {
            Text("REPS").frame(maxWidth: .infinity)
        }
    }

    private func setRow(_ exerciseIndex: Int, _ setIndex: Int, _ set: NativeWorkoutSet,
                        mode: TrainingMeasurementMode, unilateral: Bool) -> some View {
        HStack(spacing: 6) {
            setKindMenu(exerciseIndex, setIndex, set)
            metricControls(exerciseIndex, setIndex, set, mode: mode, unilateral: unilateral)
            Menu {
                Section("RPE") {
                    ForEach([5.0, 6, 7, 8, 9, 10], id: \.self) { value in
                        Button(value.formatted()) {
                            model.setEffort(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                            scale: .rpe, value: value)
                        }
                    }
                }
                Section("RIR") {
                    ForEach(0...5, id: \.self) { value in
                        Button("\(value)") {
                            model.setEffort(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                            scale: .rir, value: Double(value))
                        }
                    }
                }
            } label: {
                let prefix = set.effort?.scale == .rir ? "R" : ""
                Text(prefix + (set.effort?.value.formatted(.number.precision(.fractionLength(0...1))) ?? "—"))
                    .frame(width: 50).foregroundStyle(StrandPalette.textPrimary)
            }
            Button { model.toggleSet(exerciseIndex: exerciseIndex, setIndex: setIndex) } label: {
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(set.isCompleted ? StrandPalette.chargeColor : StrandPalette.textTertiary)
            }.buttonStyle(.plain).frame(width: 30)
        }
        .padding(.vertical, 4)
        .opacity(set.isCompleted ? 0.72 : 1)
    }

    @ViewBuilder private func metricControls(_ exerciseIndex: Int, _ setIndex: Int,
                                             _ set: NativeWorkoutSet,
                                             mode: TrainingMeasurementMode,
                                             unilateral: Bool) -> some View {
        switch mode {
        case .weightReps, .weightedBodyweight, .assistedBodyweight:
            stepControl(value: set.weightKg.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—",
                        minus: { model.adjustWeight(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -2.5) },
                        plus: { model.adjustWeight(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 2.5) })
            repsControls(exerciseIndex, setIndex, set, unilateral: unilateral)
        case .bodyweightReps, .repetitions:
            repsControls(exerciseIndex, setIndex, set, unilateral: unilateral)
        case .duration:
            stepControl(value: durationText(set.durationS),
                        minus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -5) },
                        plus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 5) })
        case .distanceDuration:
            stepControl(value: set.distanceM.map { "\(Int($0.rounded())) m" } ?? "—",
                        minus: { model.adjustDistance(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -10) },
                        plus: { model.adjustDistance(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 10) })
            stepControl(value: durationText(set.durationS),
                        minus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -5) },
                        plus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 5) })
        }
    }

    private func repsControl(_ exerciseIndex: Int, _ setIndex: Int,
                             _ set: NativeWorkoutSet) -> some View {
        stepControl(value: set.reps.map(String.init) ?? "—",
                    minus: { model.adjustReps(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -1) },
                    plus: { model.adjustReps(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 1) })
    }

    @ViewBuilder private func repsControls(_ exerciseIndex: Int, _ setIndex: Int,
                                           _ set: NativeWorkoutSet, unilateral: Bool) -> some View {
        if unilateral {
            sideRepsControl(exerciseIndex, setIndex, set, left: true)
            sideRepsControl(exerciseIndex, setIndex, set, left: false)
        } else {
            repsControl(exerciseIndex, setIndex, set)
        }
    }

    private func sideRepsControl(_ exerciseIndex: Int, _ setIndex: Int,
                                 _ set: NativeWorkoutSet, left: Bool) -> some View {
        let value = left ? set.leftReps : set.rightReps
        return stepControl(value: value.map(String.init) ?? "—",
            minus: { model.adjustSideReps(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                           left: left, by: -1) },
            plus: { model.adjustSideReps(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                          left: left, by: 1) })
    }

    private func setKindMenu(_ exerciseIndex: Int, _ setIndex: Int,
                             _ set: NativeWorkoutSet) -> some View {
        Menu {
            Button("Working set") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                                   phase: .work, intensifier: .none) }
            Button("Warm-up") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                              phase: .warmup, intensifier: .none) }
            Divider()
            Button("Drop set") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                               phase: .work, intensifier: .dropSet) }
            Button("Rest-pause") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                                 phase: .work, intensifier: .restPause) }
            Button("AMRAP") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                            phase: .work, intensifier: .amrap) }
            Button("To failure") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                                 phase: .work, intensifier: .failure) }
            Divider()
            Button("Delete set", role: .destructive) {
                model.removeSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
            }
        } label: {
            Text(setLabel(set, index: setIndex)).font(StrandFont.subhead.weight(.semibold)).frame(width: 36)
        }
    }

    private func setLabel(_ set: NativeWorkoutSet, index: Int) -> String {
        if set.phase == .warmup { return "W\(index + 1)" }
        switch set.intensifier {
        case .none: return "\(index + 1)"
        case .dropSet: return "D"
        case .restPause: return "RP"
        case .amrap: return "A"
        case .failure: return "F"
        }
    }

    private func durationText(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func stepControl(value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: minus) { Image(systemName: "minus") }.buttonStyle(.plain)
            Text(value).font(StrandFont.subhead.monospacedDigit()).frame(minWidth: 34)
            Button(action: plus) { Image(systemName: "plus") }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity)
    }

    private var finishCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Session effort").font(StrandFont.subhead.weight(.semibold))
                    Spacer(); Text("RPE \(model.sessionRPE.formatted(.number.precision(.fractionLength(1))))")
                        .font(StrandFont.subhead.monospacedDigit())
                }
                Slider(value: $model.sessionRPE, in: 1...10, step: 0.5).tint(StrandPalette.accent)
                TextField("Workout notes", text: Binding(
                    get: { model.draft.note ?? "" },
                    set: { model.setWorkoutNote($0) }), axis: .vertical)
                Button {
                    Task { if await model.finish() { onFinish(); dismiss() } }
                } label: {
                    Text("Finish workout").frame(maxWidth: .infinity).padding(.vertical, 11)
                }.buttonStyle(.borderedProminent).tint(StrandPalette.chargeColor)
            }
        }
    }

    private var exercisePicker: some View {
        NavigationStack {
            List(filteredExercises) { exercise in
                Button {
                    model.addExercise(exercise); showingExercises = false
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise.title)
                        Text(exercise.primaryMuscleId?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Other")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Text("Exercises"))
            .searchable(text: $exerciseQuery, prompt: Text("Search exercises"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingExercises = false } } }
        }
    }

    private var filteredExercises: [TrainingExercise] {
        let query = exerciseQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return exercises }
        return exercises.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.primaryMuscleId?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.equipmentIds.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

private extension View {
    @ViewBuilder
    func trainingInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private struct TrainingPlateRequest: Identifiable {
    let id = UUID()
    let targetKg: Double
}

private struct TrainingEquipmentProfile: Codable, Identifiable {
    var id: UUID
    var name: String
    var barKg: Double
    var platesKg: [Double]
}

private struct TrainingPlateCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var targetKg: Double
    @AppStorage("training.plateCalculator.barKg") private var barKg = 20.0
    @AppStorage("training.plateCalculator.available") private var availableRaw = "25,20,15,10,5,2.5,1.25"
    @AppStorage("training.plateCalculator.profiles") private var profilesRaw = "[]"
    @AppStorage("training.plateCalculator.selectedProfile") private var selectedProfileId = ""
    @State private var profileName = ""

    init(targetKg: Double) { _targetKg = State(initialValue: max(0, targetKg)) }

    var body: some View {
        Form {
            Section("Equipment profiles") {
                ForEach(profiles) { profile in
                    Button {
                        load(profile)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text("\(profile.platesKg.count) plate sizes · \(profile.barKg.formatted(.number.precision(.fractionLength(0...2)))) kg bar")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            if selectedProfileId == profile.id.uuidString {
                                Image(systemName: "checkmark").foregroundStyle(StrandPalette.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteProfiles)
                TextField("Profile name", text: $profileName)
                Button("Save current setup") { saveCurrentProfile() }
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Target") {
                HStack {
                    Text("Total weight")
                    Spacer()
                    TextField("kg", value: $targetKg, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                    Text("kg").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Bar")
                    Spacer()
                    TextField("kg", value: $barKg, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                    Text("kg").foregroundStyle(.secondary)
                }
            }
            Section("Available plates") {
                ForEach(standardPlates, id: \.self) { plate in
                    Toggle("\(plate.formatted(.number.precision(.fractionLength(0...2)))) kg",
                           isOn: Binding(get: { available.contains(plate) },
                                         set: { setPlate(plate, enabled: $0) }))
                }
            }
            Section("Load each side") {
                if let loading {
                    if loading.platesPerSideKg.isEmpty {
                        Text("Bar only").foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(loading.platesPerSideKg.enumerated()), id: \.offset) { _, plate in
                                    Text(plate.formatted(.number.precision(.fractionLength(0...2))))
                                        .font(StrandFont.subhead.weight(.bold)).foregroundStyle(.white)
                                        .frame(width: plate >= 20 ? 58 : plate >= 10 ? 50 : 42,
                                               height: plate >= 20 ? 72 : plate >= 10 ? 62 : 52)
                                        .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    LabeledContent("Achievable", value: "\(loading.achievableTotalKg.formatted(.number.precision(.fractionLength(0...2)))) kg")
                    if loading.remainderKg > 0.001 {
                        Label("\(loading.remainderKg.formatted(.number.precision(.fractionLength(0...2)))) kg cannot be loaded with this equipment.",
                              systemImage: "info.circle")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Text("The target must be at least the bar weight.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text("Plate calculator"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private let standardPlates = [25.0, 20, 15, 10, 5, 2.5, 1.25, 1, 0.5]
    private var available: [Double] {
        availableRaw.split(separator: ",").compactMap { Double($0) }.filter { $0 > 0 }.sorted(by: >)
    }
    private var loading: PlateLoading? {
        PlateCalculator.loading(totalKg: targetKg, barKg: barKg, availablePairsKg: available)
    }
    private func setPlate(_ plate: Double, enabled: Bool) {
        var values = Set(available)
        if enabled { values.insert(plate) } else { values.remove(plate) }
        availableRaw = values.sorted(by: >).map { String($0) }.joined(separator: ",")
    }

    private var profiles: [TrainingEquipmentProfile] {
        guard let data = profilesRaw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TrainingEquipmentProfile].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func load(_ profile: TrainingEquipmentProfile) {
        barKg = profile.barKg
        availableRaw = profile.platesKg.sorted(by: >).map { String($0) }.joined(separator: ",")
        selectedProfileId = profile.id.uuidString
        profileName = profile.name
    }

    private func saveCurrentProfile() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var values = profiles
        if let index = values.firstIndex(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            values[index].name = name
            values[index].barKg = barKg
            values[index].platesKg = available
            selectedProfileId = values[index].id.uuidString
        } else {
            let profile = TrainingEquipmentProfile(id: UUID(), name: name, barKg: barKg,
                                                   platesKg: available)
            values.append(profile)
            selectedProfileId = profile.id.uuidString
        }
        if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) {
            profilesRaw = text
        }
    }

    private func deleteProfiles(at offsets: IndexSet) {
        var values = profiles
        let removed = offsets.compactMap { values.indices.contains($0) ? values[$0].id.uuidString : nil }
        values.remove(atOffsets: offsets)
        if removed.contains(selectedProfileId) { selectedProfileId = "" }
        if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) {
            profilesRaw = text
        }
    }
}

private struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var routine: TrainingRoutine
    let exercises: [TrainingExercise]
    let onSave: (TrainingRoutine) -> Void
    let onDelete: (UUID) -> Void
    @State private var showingExercises = false
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section("Routine") {
                TextField("Name", text: $routine.title)
                TextField("Notes", text: Binding(get: { routine.notes ?? "" },
                                                  set: { routine.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                Toggle("Exclude from automatic progression", isOn: $routine.excludeFromProgression)
            }
            Section("Exercises") {
                ForEach(Array(routine.exercises.indices), id: \.self) { index in
                    NavigationLink {
                        RoutineExerciseEditor(entry: $routine.exercises[index],
                            exercise: exercises.first { $0.id == routine.exercises[index].exerciseId })
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercises.first { $0.id == routine.exercises[index].exerciseId }?.title
                                     ?? routine.exercises[index].exerciseId)
                                if routine.exercises[index].supersetId != nil {
                                    Label("Superset", systemImage: "link")
                                        .font(.caption).foregroundStyle(StrandPalette.metricCyan)
                                }
                            }
                            Spacer(); Text("\(routine.exercises[index].sets.count) sets").foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if routine.exercises.indices.contains(index + 1) {
                            Button("Superset") { supersetWithNext(index) }.tint(StrandPalette.metricCyan)
                        }
                    }
                }
                .onDelete { routine.exercises.remove(atOffsets: $0); cleanSupersets() }
                .onMove { routine.exercises.move(fromOffsets: $0, toOffset: $1) }
                Button("Add exercise") { showingExercises = true }
            }
            Section("Progression") {
                Picker("Method", selection: $routine.defaultProgression.policy) {
                    Text("Off").tag(ProgressionPolicy.off)
                    Text("Linear").tag(ProgressionPolicy.linear)
                    Text("Double progression").tag(ProgressionPolicy.doubleProgression)
                    Text("Greyskull LP").tag(ProgressionPolicy.greyskullLP)
                    Text("Time progression").tag(ProgressionPolicy.time)
                }
                if routine.defaultProgression.policy != .off {
                    Stepper("Rep range: \(routine.defaultProgression.repsMin)–\(routine.defaultProgression.repsMax)",
                            value: $routine.defaultProgression.repsMax,
                            in: routine.defaultProgression.repsMin...50)
                    Stepper("Weight step: \(routine.defaultProgression.weightIncrementKg.formatted(.number.precision(.fractionLength(0...2)))) kg",
                            value: $routine.defaultProgression.weightIncrementKg, in: 0.5...20, step: 0.5)
                    Stepper("Deload after \(routine.defaultProgression.failuresBeforeDeload) misses",
                            value: $routine.defaultProgression.failuresBeforeDeload, in: 1...8)
                }
            }
            Section {
                Button("Delete routine", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(Text("Edit routine"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { routine.updatedAt = Int(Date().timeIntervalSince1970); onSave(routine); dismiss() }
                    .disabled(routine.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: $showingExercises) {
            NavigationStack {
                List(exercises) { exercise in
                    Button(exercise.title) {
                        routine.exercises.append(.init(exerciseId: exercise.id,
                            sets: (0..<3).map { _ in .init(repsMin: 8, repsMax: 12) }))
                        showingExercises = false
                    }
                }.navigationTitle(Text("Exercises"))
            }
        }
        .confirmationDialog("Delete this routine?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) { onDelete(routine.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed workouts stay in your history.")
        }
    }

    private func supersetWithNext(_ index: Int) {
        guard routine.exercises.indices.contains(index), routine.exercises.indices.contains(index + 1) else { return }
        let group = routine.exercises[index].supersetId ?? UUID()
        routine.exercises[index].supersetId = group
        routine.exercises[index + 1].supersetId = group
    }

    private func cleanSupersets() {
        let counts = Dictionary(grouping: routine.exercises.compactMap(\.supersetId), by: { $0 }).mapValues(\.count)
        for index in routine.exercises.indices {
            if let group = routine.exercises[index].supersetId, counts[group, default: 0] < 2 {
                routine.exercises[index].supersetId = nil
            }
        }
    }
}

private struct RoutineExerciseEditor: View {
    @Binding var entry: RoutineExercise
    let exercise: TrainingExercise?

    var body: some View {
        Form {
            Section {
                Stepper("Rest: \(entry.restSeconds) sec", value: $entry.restSeconds, in: 0...600, step: 15)
                if exercise?.mode == .weightReps {
                    HStack {
                        Text("Bar weight")
                        Spacer()
                        TextField("kg", value: Binding(get: { entry.barWeightKg ?? 20 },
                            set: { entry.barWeightKg = $0 }), format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                        Text("kg").foregroundStyle(.secondary)
                    }
                }
                TextField("Exercise notes", text: Binding(get: { entry.note ?? "" },
                    set: { entry.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }
            Section("Sets") {
                ForEach(Array(entry.sets.indices), id: \.self) { index in
                    RoutineSetEditor(set: $entry.sets[index], mode: exercise?.mode ?? .weightReps,
                                     number: index + 1)
                }
                .onDelete { entry.sets.remove(atOffsets: $0) }
                Button("Add working set") { entry.sets.append(.init(repsMin: 8, repsMax: 12)) }
                Button("Add warm-up set") { entry.sets.append(.init(phase: .warmup, repsMin: 8, repsMax: 8)) }
            }
            Section("Progression override") {
                Picker("Method", selection: Binding(get: { entry.progression?.policy ?? .off }, set: { value in
                    entry.progression = value == .off ? nil : ProgressionConfiguration(policy: value)
                })) {
                    Text("Use routine default").tag(ProgressionPolicy.off)
                    Text("Linear").tag(ProgressionPolicy.linear)
                    Text("Double progression").tag(ProgressionPolicy.doubleProgression)
                    Text("Greyskull LP").tag(ProgressionPolicy.greyskullLP)
                    Text("Time progression").tag(ProgressionPolicy.time)
                }
            }
        }
        .navigationTitle(exercise?.title ?? String(localized: "Exercise"))
    }
}

private struct RoutineSetEditor: View {
    @Binding var set: RoutineSetPlan
    let mode: TrainingMeasurementMode
    let number: Int

    var body: some View {
        DisclosureGroup("Set \(number) · \(kind)") {
            Picker("Type", selection: $set.phase) {
                Text("Working set").tag(TrainingSetPhase.work)
                Text("Warm-up").tag(TrainingSetPhase.warmup)
            }
            Picker("Technique", selection: $set.intensifier) {
                Text("Normal").tag(TrainingSetIntensifier.none)
                Text("Drop set").tag(TrainingSetIntensifier.dropSet)
                Text("Rest-pause").tag(TrainingSetIntensifier.restPause)
                Text("AMRAP").tag(TrainingSetIntensifier.amrap)
                Text("To failure").tag(TrainingSetIntensifier.failure)
            }
            switch mode {
            case .weightReps, .weightedBodyweight, .assistedBodyweight:
                optionalNumber("Target weight", value: $set.targetWeightKg, suffix: "kg")
                repRange
            case .bodyweightReps, .repetitions:
                repRange
            case .duration:
                optionalInteger("Target time", value: $set.targetDurationS, suffix: "sec")
            case .distanceDuration:
                optionalNumber("Target distance", value: $set.targetDistanceM, suffix: "m")
                optionalInteger("Target time", value: $set.targetDurationS, suffix: "sec")
            }
        }
    }

    private var kind: String {
        if set.phase == .warmup { return String(localized: "Warm-up") }
        switch set.intensifier {
        case .none: return String(localized: "Working set")
        case .dropSet: return String(localized: "Drop set")
        case .restPause: return String(localized: "Rest-pause")
        case .amrap: return "AMRAP"
        case .failure: return String(localized: "To failure")
        }
    }

    private var repRange: some View {
        VStack {
            optionalInteger("Minimum reps", value: $set.repsMin, suffix: "")
            optionalInteger("Maximum reps", value: $set.repsMax, suffix: "")
        }
    }

    private func optionalNumber(_ title: LocalizedStringKey, value: Binding<Double?>,
                                suffix: String) -> some View {
        HStack {
            Text(title); Spacer()
            TextField("—", value: value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing).frame(width: 90)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
    }

    private func optionalInteger(_ title: LocalizedStringKey, value: Binding<Int?>,
                                 suffix: String) -> some View {
        HStack {
            Text(title); Spacer()
            TextField("—", value: value, format: .number)
                .multilineTextAlignment(.trailing).frame(width: 90)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
    }
}

private struct TrainingScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let routines: [TrainingRoutine]
    let onSave: ([TrainingWeekday: [UUID]]) -> Void
    @State private var schedule: [TrainingWeekday: [UUID]]

    init(plan: TrainingPlan, onSave: @escaping ([TrainingWeekday: [UUID]]) -> Void) {
        routines = plan.routines
        self.onSave = onSave
        _schedule = State(initialValue: plan.schedule)
    }

    var body: some View {
        List {
            if routines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.title2).foregroundStyle(StrandPalette.textTertiary)
                    Text("No routines yet").font(StrandFont.subhead.weight(.semibold))
                    Text("Create or add a routine before building your week.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(TrainingWeekday.allCases, id: \.rawValue) { weekday in
                    Section(weekday.title) {
                        ForEach(routines) { routine in
                            Toggle(routine.title, isOn: Binding(
                                get: { schedule[weekday, default: []].contains(routine.id) },
                                set: { enabled in set(routine.id, on: weekday, enabled: enabled) }))
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("Weekly schedule"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(schedule); dismiss() }.disabled(routines.isEmpty)
            }
        }
    }

    private func set(_ routineId: UUID, on weekday: TrainingWeekday, enabled: Bool) {
        var ids = schedule[weekday] ?? []
        if enabled {
            if !ids.contains(routineId) { ids.append(routineId) }
        } else {
            ids.removeAll { $0 == routineId }
        }
        schedule[weekday] = ids
    }
}

private struct TrainingDayEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let routines: [TrainingRoutine]
    let onSave: (TrainingDayOverride) -> Void
    let onReset: (String) -> Void
    @State private var selected: Set<UUID>
    @State private var isRest: Bool
    private let day: String

    init(date: Date, plan: TrainingPlan,
         onSave: @escaping (TrainingDayOverride) -> Void,
         onReset: @escaping (String) -> Void) {
        self.date = date
        routines = plan.routines
        self.onSave = onSave
        self.onReset = onReset
        let dayKey = TrainingHubModel.dayString(date)
        day = dayKey
        let existing = plan.overrides.last { $0.day == dayKey }
        let weekly = plan.schedule[TrainingHubModel.weekday(date)] ?? []
        _selected = State(initialValue: Set(existing?.routineIds ?? weekly))
        _isRest = State(initialValue: existing?.isRest ?? false)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Rest day", isOn: $isRest)
            } footer: {
                Text("A day change affects this date only. Your weekly schedule stays intact.")
            }
            if !isRest {
                Section("Routines") {
                    ForEach(routines) { routine in
                        Toggle(routine.title, isOn: Binding(
                            get: { selected.contains(routine.id) },
                            set: { enabled in
                                if enabled { selected.insert(routine.id) }
                                else { selected.remove(routine.id) }
                            }))
                    }
                }
            }
            Section {
                Button("Use weekly schedule") { onReset(day); dismiss() }
            }
        }
        .navigationTitle(date.formatted(.dateTime.weekday(.wide).day().month()))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let ordered = routines.map(\.id).filter(selected.contains)
                    onSave(TrainingDayOverride(day: day, routineIds: ordered, isRest: isRest))
                    dismiss()
                }
            }
        }
    }
}

private extension TrainingWeekday {
    var title: LocalizedStringKey {
        switch self {
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }
}
