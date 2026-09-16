import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandTraining
import WhoopStore
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Native training home inspired by OpenGym's useful structure while keeping NOOP's own visual system,
/// source provenance, analytics and data model. No OpenGym source, strings or assets are included.
struct TrainingHubView: View {
    // Deliberately not `AppModel`: it republishes on every heart-rate tick, and this screen's body is the
    // most expensive in the app. The session controller changes only when a session starts or ends.
    @EnvironmentObject private var session: ActiveSessionController
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = TrainingHubModel()
    @State private var showingStarterPlans = false
    @State private var showingSchedule = false
    @State private var showingLibrary = false
    @State private var showingPlanImporter = false
    @State private var showingHistoryImporter = false
    @State private var showingPastWorkout = false
    @State private var editingDay: TrainingDaySelection?
    @State private var editingRoutine: TrainingRoutine?
    @State private var previewRoutine: TrainingRoutine?
    @State private var showingAddRoutineSheet = false
    @State private var routineActionsFor: TrainingRoutine?
    @AppStorage("training.weekStartsOn") private var weekStartRaw = TrainingWeekStart.monday.rawValue

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
                    TrainingActivityHeatmap(days: model.activityDays)
                    TrainingMuscleMapCard(history: model.resolvedHistory)
                    analysisCard
                    recentCard
                }
                DemoScrollBottomAnchor()
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Training"))
        .task(id: "\(repo.refreshSeq)|\(weekStartRaw)") {
            await model.load(repo: repo, session: session, weekStartsOn: weekStart)
        }
        // A finished session changes history; reload once it is over rather than on every refresh during it.
        .onChange(of: session.hasLiveSession) { live in
            guard !live else { return }
            Task { await model.load(repo: repo, session: session, weekStartsOn: weekStart, force: true) }
        }
        .sheet(item: $model.historyImportPreview) { preview in
            TrainingHistoryImportPreviewView(preview: preview,
                onCancel: { model.historyImportPreview = nil },
                onImport: { Task { await model.confirmHistoryImport(repo: repo) } })
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
                TrainingExerciseLibraryView(
                    exercises: model.exercises,
                    performance: model.performanceHistory,
                    onAddToWorkout: session.strength.map { strength in
                        { exercise in strength.addExercise(exercise) }
                    },
                    onSave: { exercise in
                        Task { await model.saveExercise(exercise, repo: repo) }
                    })
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
                RoutineEditorView(routine: routine,
                    weekdays: RoutineEditing.weekdays(of: routine.id, in: model.plan.schedule),
                    exercises: model.exercises,
                    onSave: { updated, weekdays in
                        Task { await model.saveRoutine(updated, weekdays: weekdays, repo: repo) }
                    },
                    onDelete: { id in Task { await model.deleteRoutine(id, repo: repo) } })
            }
        }
        .sheet(isPresented: $showingAddRoutineSheet) {
            NavigationStack {
                AddRoutineActionsSheet(
                    onLibrary: { showingLibrary = true },
                    onAddRoutine: { showingStarterPlans = true },
                    onShare: { exportPlan() },
                    onExportPDF: { exportPlanPDF() },
                    onImportPlan: { showingPlanImporter = true },
                    onImportHistory: { showingHistoryImporter = true },
                    onLogPastWorkout: { showingPastWorkout = true })
            }
        }
        .sheet(item: $routineActionsFor) { routine in
            NavigationStack {
                RoutineActionsSheet(
                    routine: routine,
                    onPreview: { previewRoutine = routine },
                    onEdit: { editingRoutine = routine },
                    onDuplicate: { Task { await model.duplicateRoutine(routine, repo: repo) } })
            }
        }
        .sheet(item: $previewRoutine) { routine in
            NavigationStack {
                TrainingRoutinePreviewView(routine: routine, exercises: model.exerciseById,
                    weekdays: RoutineEditing.weekdays(of: routine.id, in: model.plan.schedule)) {
                    previewRoutine = nil
                    start([routine])
                }
            }
        }
        .sheet(isPresented: $showingPastWorkout) {
            NavigationStack {
                PastWorkoutStartView(routines: model.plan.routines, trackers: model.trackers) {
                    routines, tracker, date, duration in
                    showingPastWorkout = false
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        await session.startRetrospective(routines: routines, tracker: tracker,
                                                         date: date, durationS: duration)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showingPlanImporter, allowedContentTypes: [.json]) { result in
            consume(result) { data in await model.importPlan(data, repo: repo) }
        }
        .fileImporter(isPresented: $showingHistoryImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            consume(result) { data in model.prepareHistoryImport(data) }
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
        }
    }

    private var startCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.hasLiveSession ? "Workout in progress" : "Ready to train?")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(session.hasLiveSession
                            ? session.runningTitle
                            : String(localized: "Log every set locally and keep its source."))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "dumbbell.fill")
                        .font(.title2).foregroundStyle(StrandPalette.accent)
                }

                if session.hasLiveSession {
                    Button { session.present() } label: {
                        Label("Resume workout", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                } else if !model.routines(on: Date()).isEmpty {
                    let today = model.routines(on: Date())
                    Button { start(today) } label: {
                        Label("Start today's plan", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                } else {
                    HStack(spacing: 10) {
                        Button { start([]) } label: {
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
                Button { showingAddRoutineSheet = true } label: {
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
                            let muscles = TrainingMuscleProjection.routine(
                                routine, exercises: model.exerciseById)
                            if muscles.isEmpty {
                                Image(systemName: "list.bullet.rectangle.fill")
                                    .foregroundStyle(StrandPalette.accent).font(.title3)
                                    .frame(width: 72)
                            } else {
                                TrainingMiniMusclePreview(values: muscles)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(routine.title).font(StrandFont.headline)
                                Text("\(routine.exercises.count) exercises")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            Button { start([routine]) } label: {
                                Image(systemName: "play.fill")
                            }.buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                            .accessibilityLabel(Text("Start \(routine.title)"))
                            Button { routineActionsFor = routine } label: {
                                Image(systemName: "ellipsis.circle")
                                    .accessibilityLabel(Text("Routine options"))
                            }
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
                if model.resolvedHistory.sessions.isEmpty {
                    Text("Your completed workouts will appear here.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.resolvedHistory.sessions.prefix(5)) { session in
                            NavigationLink {
                                StrengthSessionDetailView(
                                    breakdown: StrengthDetail.breakdown(
                                        session.workout,
                                        templates: model.resolvedHistory.templates),
                                    matchedRow: session.canonicalRow,
                                    source: session.workout.source)
                            } label: {
                              HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.workout.title).font(StrandFont.subhead.weight(.semibold))
                                    Text("\(session.workout.exercises.count) exercises · \(session.workingSetCount) work sets")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer()
                                Text(Date(timeIntervalSince1970: TimeInterval(session.startTs)), style: .date)
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

    private var weekStart: TrainingWeekStart {
        TrainingWeekStart(rawValue: weekStartRaw) ?? .monday
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
        let recent = model.resolvedHistory.sessions.filter {
            $0.startTs >= Int(Date().timeIntervalSince1970) - 28 * 86_400
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

    /// Every start goes through the one session controller, so the Training tab and Today build the
    /// same session and a running one is never replaced without asking.
    private func start(_ routines: [TrainingRoutine]) {
        session.requestStrength(routines: routines)
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

private struct TrainingHistoryImportPreviewView: View {
    let preview: TrainingHubModel.HistoryImportPreview
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Ready to import") {
                    LabeledContent("Workouts", value: preview.workoutCount.formatted())
                    LabeledContent("Exercises", value: preview.exerciseCount.formatted())
                    LabeledContent("Sets", value: preview.setCount.formatted())
                }
                Section("Muscle mapping") {
                    LabeledContent("Mapped automatically",
                                   value: "\(preview.mappedExerciseCount) of \(preview.exerciseCount)")
                    Text("Mapped exercises flow directly into Strength, Training Load and the shared muscle map. Unknown exercises keep their original sets and can be assigned later.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if preview.result.skippedRows > 0 {
                    Section("Review") {
                        Label("\(preview.result.skippedRows) incomplete rows will be skipped",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                }
                Section {
                    Text("Only the normalized exercises and completed sets are stored. The selected import file is not copied into NOOP.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .navigationTitle(Text("Import preview"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Import", action: onImport) }
            }
        }
    }
}

struct StrengthWorkoutSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @State private var workout: NativeWorkout
    let exercises: [TrainingExercise]
    let performance: TrainingPerformanceHistory
    @State private var highlights: StrengthSessionHighlights?
    @State private var canonicalRow: WorkoutRow?
    @State private var hrPoints: [TrendPoint] = []
    @State private var zoneMinutes: [Double]?
    @State private var loadedPhysiology = false
    @State private var titleSaveTask: Task<Void, Never>?

    init(workout: NativeWorkout, exercises: [TrainingExercise], performance: TrainingPerformanceHistory) {
        _workout = State(initialValue: workout)
        self.exercises = exercises
        self.performance = performance
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NoopMetrics.sectionGap) {
                    NoopCard(tint: StrandPalette.chargeColor) {
                        VStack(spacing: NoopMetrics.space3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 46)).foregroundStyle(StrandPalette.chargeColor)
                            Text("Workout complete").font(StrandFont.title1.weight(.bold))
                            Text(workout.title).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            HStack(spacing: NoopMetrics.space4) {
                                summary("Active", duration(summary.activeDurationS))
                                summary("Work sets", summary.workingSetCount.formatted())
                                if let rpe = workout.sessionRPE {
                                    summary("Session RPE", rpe.formatted(.number.precision(.fractionLength(0...1))))
                                }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    sessionFacts
                    progress
                    let muscles = TrainingMuscleProjection.workout(workout, exercises: exerciseById)
                    if !muscles.isEmpty {
                        NoopCard {
                            HStack(spacing: NoopMetrics.space4) {
                                TrainingMiniMusclePreview(values: muscles)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Muscles trained").font(StrandFont.headline)
                                    Text(topMuscles(muscles).joined(separator: " · "))
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    heartRate
                    zones
                    exerciseBreakdown
                    titleCard
                    sessionNote
                    SessionRPECard(startTs: workout.startedAt, sport: workout.title,
                                   durationS: Double(summary.activeDurationS))
                    provenance
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text("Summary"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                highlights = StrengthSessionHighlights.make(workout: workout, exercises: exerciseById,
                                                            history: performance)
                await loadPhysiology()
            }
        }
    }

    private var summary: NativeWorkoutSummary { NativeWorkoutEngine.summary(for: workout) }

    private var exerciseById: [String: TrainingExercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    private var sessionFacts: some View {
        NoopCard {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: NoopMetrics.gap)],
                      alignment: .leading, spacing: NoopMetrics.gap) {
                fact("Elapsed", duration(summary.elapsedDurationS))
                fact("Warm-up sets", summary.warmupSetCount.formatted())
                fact("Exercises", summary.exerciseCount.formatted())
                if summary.loadedVolumeKg > 0 { fact("Loaded volume", volume(summary.loadedVolumeKg)) }
                if let rpe = workout.sessionRPE, summary.activeDurationS > 0 {
                    fact("Session Load", "\(Int((rpe * Double(summary.activeDurationS) / 60).rounded())) AU")
                }
            }
        }
    }

    /// Records and per-exercise movement against this wearer's own earlier sessions.
    @ViewBuilder private var progress: some View {
        if let highlights, !highlights.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Progress", overline: "Against your own history")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        ForEach(highlights.records) { record in
                            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                                Image(systemName: "trophy.fill")
                                    .font(.caption).foregroundStyle(StrandPalette.metricAmber)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.exerciseTitle).font(StrandFont.subhead.weight(.semibold))
                                    Text(recordText(record))
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if !highlights.changes.isEmpty {
                            if !highlights.records.isEmpty { Divider().overlay(StrandPalette.hairline) }
                            ForEach(highlights.changes) { change in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(change.exerciseTitle).font(StrandFont.subhead)
                                    Spacer(minLength: NoopMetrics.space2)
                                    Text(changeText(change))
                                        .font(StrandFont.caption.monospacedDigit())
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .multilineTextAlignment(.trailing)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        Text("A record compares this session with every earlier session of the same exercise. An estimated one-rep maximum is a projection, not a lift you performed.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func recordText(_ record: StrengthSessionHighlights.Record) -> String {
        let value = TrainingSetText.weight(record.valueKg)
        let previous = TrainingSetText.weight(record.previousKg)
        switch record.kind {
        case .estimatedOneRepMax:
            return String(localized: "New estimated 1RM: \(value) kg, previously \(previous) kg")
        case .heaviestSet:
            return String(localized: "New heaviest set: \(value) kg, previously \(previous) kg")
        }
    }

    private func changeText(_ change: StrengthSessionHighlights.Change) -> String {
        var parts: [String] = []
        if let delta = change.deltaKg {
            parts.append("\(delta.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always()))) kg")
        }
        if let reps = change.deltaReps {
            parts.append(String(localized: "\(reps.formatted(.number.sign(strategy: .always()))) reps"))
        }
        let date = Date(timeIntervalSince1970: TimeInterval(change.previousTs))
            .formatted(date: .abbreviated, time: .omitted)
        return String(localized: "\(parts.joined(separator: " · ")) versus \(date)")
    }

    /// Every exercise with the sets as they were logged, including warm-ups and exercise notes.
    private var exerciseBreakdown: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Exercises", overline: "What you logged")
            ForEach(workout.exercises) { exercise in
                let definition = exerciseById[exercise.exerciseId]
                NoopCard {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(definition?.title ?? exercise.exerciseId)
                                .font(StrandFont.subhead.weight(.semibold))
                            Spacer()
                            if exercise.supersetId != nil {
                                Label("Superset", systemImage: "link")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.metricCyan)
                            }
                        }
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                            HStack(spacing: 8) {
                                Text(set.phase == .warmup ? "W" : (index + 1).formatted())
                                    .font(StrandFont.caption.weight(.bold)).frame(width: 22)
                                    .foregroundStyle(set.phase == .warmup ? StrandPalette.textTertiary
                                                                          : StrandPalette.textSecondary)
                                Text(TrainingSetText.summary(.init(set), mode: definition?.mode ?? .weightReps,
                                                             unilateral: definition?.isUnilateral == true))
                                    .font(StrandFont.caption.monospacedDigit())
                                Spacer()
                                if let effort = set.effort {
                                    Text(TrainingSetText.effort(effort))
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if let note = exercise.note, !note.isEmpty {
                            Text(note).font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// A default title ("Freestyle workout", or the routine names) is set at start; this lets a wearer
    /// replace it once they know what the session turned out to be. Debounced like the in-session note,
    /// since every keystroke would otherwise re-write the workout's exercises and sets in SQLite.
    private var titleCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 5) {
                Text("Workout title").font(StrandFont.subhead.weight(.semibold))
                TextField("Workout title (optional)", text: Binding(
                    get: { workout.title },
                    set: { newTitle in
                        workout.title = newTitle
                        titleSaveTask?.cancel()
                        titleSaveTask = Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            guard !Task.isCancelled else { return }
                            try? await repo.renameNativeWorkout(workout, title: newTitle)
                        }
                    }))
            }
        }
    }

    @ViewBuilder private var sessionNote: some View {
        if let note = workout.note, !note.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Session note").font(StrandFont.subhead.weight(.semibold))
                    Text(note).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var heartRate: some View {
        if hrPoints.count >= 3 {
            ChartCard(title: "HEART RATE", subtitle: "Recorded during this workout",
                      trailing: canonicalRow?.avgHr.map { String(localized: "avg \($0)") },
                      tint: StrandPalette.metricRose) {
                TrendChart(points: hrPoints, gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.3), StrandPalette.metricRose]),
                           valueRange: hrRange, height: 130,
                           valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                           dateFormat: { $0.formatted(date: .omitted, time: .shortened) },
                           accessibilityLabel: String(localized: "Heart rate during this workout"))
            } footer: {
                ChartFooter([
                    ("Avg", canonicalRow?.avgHr.map { "\($0) bpm" } ?? "–"),
                    ("Peak", canonicalRow?.maxHr.map { "\($0) bpm" } ?? "–")
                ])
            }
        } else if loadedPhysiology, workout.physiologyProvider != WorkoutPhysiologyProvider.none {
            NoopCard {
                Label("No heart-rate samples are available for this workout.", systemImage: "heart.slash")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    @ViewBuilder private var zones: some View {
        if let zones = zoneMinutes, zones.count == 5, zones.reduce(0, +) > 0 {
            let total = zones.reduce(0, +)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("HR Zones", overline: "Recorded heart rate",
                              trailing: String(localized: "\(Int(total.rounded()))m in zone"))
                NoopCard(tint: StrandPalette.effortColor) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { index in
                                Rectangle().fill(StrandPalette.hrZoneColor(index + 1))
                                    .frame(width: max(0, CGFloat(zones[index] / total) * geo.size.width))
                            }
                        }
                    }
                    .frame(height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(String(localized: "Heart-rate zone split"))
                }
            }
        }
    }

    private var provenance: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 5) {
                Text("Data source").font(StrandFont.subhead.weight(.semibold))
                Text(sourceDescription).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if let coverage = workout.hrCoverage {
                    Text(String(localized: "Heart-rate coverage: \(Int((coverage * 100).rounded()))%"))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var sourceDescription: String {
        switch workout.physiologyProvider {
        case .appleWatch: return String(localized: "Sets logged in NOOP · heart rate from Apple Watch")
        case .noopBand: return String(localized: "Sets logged in NOOP · heart rate from NOOP band")
        case .externalTracker: return String(localized: "Sets logged in NOOP · heart rate from selected tracker")
        case .some(.none), nil:
            return String(localized: "Sets logged in NOOP · no heart-rate tracker selected")
        }
    }

    private var hrRange: ClosedRange<Double> {
        let values = hrPoints.map(\.value)
        guard let low = values.min(), let high = values.max(), high > low else { return 40...180 }
        let padding = max(5, (high - low) * 0.15)
        return max(30, low - padding)...(high + padding)
    }

    private func loadPhysiology() async {
        let history = await repo.resolvedStrengthHistory(days: 2)
        let id = "noop-native:\(workout.id.uuidString)"
        guard let session = history.sessions.first(where: { $0.workout.id == id }) else {
            loadedPhysiology = true
            return
        }
        canonicalRow = session.canonicalRow
        let source = session.canonicalRow?.source ?? ""
        let buckets = await repo.workoutHrBuckets(from: workout.startedAt, to: workout.endedAt, source: source)
        hrPoints = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        zoneMinutes = await repo.workoutZoneMinutes(from: workout.startedAt, to: workout.endedAt,
                                                    zoneSet: profile.hrZoneSet, source: source)
        loadedPhysiology = true
    }

    private func duration(_ seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinute))
    }

    private func volume(_ kilograms: Double) -> String {
        kilograms >= 1_000 ? "\((kilograms / 1_000).formatted(.number.precision(.fractionLength(1)))) t"
            : "\(Int(kilograms.rounded()).formatted()) kg"
    }

    private func summary(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(StrandFont.number(20)).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }.frame(maxWidth: .infinity)
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(StrandFont.number(18)).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func topMuscles(_ values: [String: Double]) -> [String] {
        values.sorted { $0.value > $1.value }.prefix(5).map { item in
            TrainingDisplayNames.muscle(item.key)
        }
    }
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

private enum ActiveWorkoutLayout: String, CaseIterable, Identifiable {
    case focus
    case list
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: String(localized: "One exercise")
        case .list: String(localized: "All exercises")
        case .compact: String(localized: "Compact")
        }
    }

    var symbol: String {
        switch self {
        case .focus: "viewfinder"
        case .list: "list.bullet"
        case .compact: "rectangle.compress.vertical"
        }
    }
}

/// The strength logger. It edits the controller's session model and never owns the session: closing it
/// minimizes, and only Finish or Discard end the workout.
struct NativeWorkoutLoggerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: ActiveSessionController
    @ObservedObject private var model: NativeWorkoutSessionModel
    @ObservedObject private var media = ExerciseMediaStore.shared
    let exercises: [TrainingExercise]
    let performance: TrainingPerformanceHistory
    @State private var showingExercises = false
    @State private var plateRequest: TrainingPlateRequest?
    @State private var replacementExerciseId: UUID?
    @State private var confirmingPartialFinish = false
    @State private var confirmingDiscard = false
    @FocusState private var focusedSetField: TrainingSetField?
    @State private var historyRequest: TrainingHistoryRequest?
    @State private var effortRequest: EffortPickerRequest?
    @State private var showingRoutinePicker = false
    @StateObject private var liveEffort = StrengthLiveEffort()
    @AppStorage("training.activeWorkout.layout") private var layoutRaw = ActiveWorkoutLayout.focus.rawValue
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false
    @AppStorage(TrainingPreferences.effortKey) private var effortRaw = TrainingEffortPreference.rpe.rawValue
    @AppStorage(TrainingPreferences.mediaPresentationKey) private var mediaPresentationRaw = TrainingMediaPresentation.large.rawValue
    @AppStorage(TrainingPreferences.hapticsKey) private var hapticsEnabled = true
    #if os(macOS)
    @State private var macActivity: NSObjectProtocol?
    #endif

    init(model: NativeWorkoutSessionModel, exercises: [TrainingExercise],
         performance: TrainingPerformanceHistory) {
        self.model = model
        self.exercises = exercises
        self.performance = performance
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    WorkoutLoggerHeader(model: model)
                    if !model.isRetrospective { physiologyCard }
                    workoutContent
                    Button { showingExercises = true } label: {
                        Label("Add exercise", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.bordered).tint(StrandPalette.accent)
                    noteCard
                }.padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            // The rest countdown stays in view while scrolling through sets.
            .safeAreaInset(edge: .bottom) {
                if let timer = model.activeTimer {
                    WorkoutRestDock(timer: timer, model: model, onFinished: timerFinishedFeedback)
                }
            }
            .navigationTitle(model.draft.title)
            .trainingInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Minimizes. The session keeps running and stays one tap away.
                    Button { session.minimize() } label: { Label("Back", systemImage: "chevron.down") }
                }
                ToolbarItem(placement: .primaryAction) { sessionMenu }
                ToolbarItem(placement: .confirmationAction) {
                    // The one, clearly primary way to end the workout — colored so it doesn't read
                    // as an ordinary nav-bar action next to "Back" and the "..." menu.
                    Button("Finish") { requestFinish() }
                        .fontWeight(.semibold)
                        .tint(StrandPalette.chargeColor)
                }
            }
            .trainingKeyboardDoneButton { focusedSetField = nil }
            .sheet(isPresented: $showingExercises) { exercisePicker }
            .sheet(item: $plateRequest) { request in
                NavigationStack { TrainingPlateCalculatorView(targetKg: request.targetKg) }
            }
            .sheet(item: $effortRequest) { request in
                EffortPickerSheet(request: request) { value in
                    if let value {
                        model.setEffort(exerciseIndex: request.exerciseIndex, setIndex: request.setIndex,
                                        scale: request.scale, value: value)
                    } else {
                        model.clearEffort(exerciseIndex: request.exerciseIndex, setIndex: request.setIndex)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingRoutinePicker) { routinePicker }
            .sheet(item: $historyRequest) { request in
                NavigationStack {
                    TrainingExerciseHistorySheet(
                        title: request.title, mode: request.mode, unilateral: request.unilateral,
                        entries: Array(performance.entries(for: request.id).reversed()))
                }
            }
            .alert("Workout", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
            .confirmationDialog("Incomplete sets", isPresented: $confirmingPartialFinish,
                                titleVisibility: .visible) {
                Button("Finish completed sets", role: .destructive) { finishNow() }
                Button("Keep logging", role: .cancel) {}
            } message: {
                Text("Some sets are incomplete. Only completed sets will be saved.")
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard workout", role: .destructive) { discardNow() }
                Button("Keep logging", role: .cancel) {}
            } message: {
                Text("Every set logged in this session is deleted and nothing is added to your history. This cannot be undone.")
            }
            .onChange(of: model.watchFinishRequested) { requested in
                guard requested else { return }
                requestFinish()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.appReturnedToForeground() }
                else if phase == .background { model.appMovedToBackground() }
            }
            // Live heart rate is only worth streaming while someone is looking at it; the session's
            // stored heart rate does not depend on it.
            .onAppear {
                guard !model.isRetrospective else { return }
                session.startLiveHeartRate()
                liveEffort.start(repo: session.repository, draft: { [model] in model.draft },
                                 profile: session.profile)
            }
            .onDisappear {
                guard !model.isRetrospective else { return }
                session.stopLiveHeartRate()
                liveEffort.stop()
            }
            #if os(iOS)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
            .onChange(of: keepScreenOn) { UIApplication.shared.isIdleTimerDisabled = $0 }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            #elseif os(macOS)
            .onAppear {
                if keepScreenOn {
                    macActivity = ProcessInfo.processInfo.beginActivity(
                        options: [.userInitiated, .idleSystemSleepDisabled],
                        reason: "Workout logging")
                }
            }
            .onDisappear {
                if let macActivity { ProcessInfo.processInfo.endActivity(macActivity) }
                macActivity = nil
            }
            #endif
        }
    }

    private var layout: ActiveWorkoutLayout {
        ActiveWorkoutLayout(rawValue: layoutRaw) ?? .focus
    }

    private var effortPreference: TrainingEffortPreference {
        TrainingEffortPreference(rawValue: effortRaw) ?? .rpe
    }

    @ViewBuilder private var workoutContent: some View {
        switch layout {
        case .focus:
            if model.draft.exercises.indices.contains(model.activeExerciseIndex) {
                exerciseNavigator
                exerciseCard(model.activeExerciseIndex, model.draft.exercises[model.activeExerciseIndex])
            }
        case .list:
            ForEach(Array(model.draft.exercises.enumerated()), id: \.element.id) { index, exercise in
                exerciseCard(index, exercise)
            }
        case .compact:
            ForEach(Array(model.draft.exercises.enumerated()), id: \.element.id) { index, exercise in
                compactExerciseCard(index, exercise)
            }
        }
    }

    private var exerciseNavigator: some View {
        HStack(spacing: NoopMetrics.space2) {
            Button {
                model.selectExercise(at: model.activeExerciseIndex - 1)
            } label: { Label("Back", systemImage: "chevron.left") }
            .disabled(model.activeExerciseIndex == 0)
            Spacer()
            Text("\(model.activeExerciseIndex + 1) / \(model.draft.exercises.count)")
                .font(StrandFont.caption.monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button {
                model.selectExercise(at: model.activeExerciseIndex + 1)
            } label: { Label("Next", systemImage: "chevron.right") }
            .disabled(model.activeExerciseIndex + 1 >= model.draft.exercises.count)
        }
        .font(StrandFont.caption.weight(.semibold))
    }

    private var physiologyCard: some View {
        StrengthLiveHeartRatePanel(provider: model.draft.physiologyProvider ?? .none,
                                   sourceText: physiologySource,
                                   watchFeed: session.watchHeartRate, effort: liveEffort)
    }

    /// Session-wide actions, kept out of the logging surface.
    private var sessionMenu: some View {
        Menu {
            Button { showingExercises = true } label: { Label("Add exercise", systemImage: "plus") }
            if !session.context.plan.routines.isEmpty {
                Button { showingRoutinePicker = true } label: {
                    Label("Add routine", systemImage: "list.bullet.rectangle")
                }
            }
            Picker(selection: $layoutRaw) {
                ForEach(ActiveWorkoutLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.symbol).tag(layout.rawValue)
                }
            } label: {
                Label("Layout", systemImage: ActiveWorkoutLayout(rawValue: layoutRaw)?.symbol ?? "viewfinder")
            }
            .pickerStyle(.menu)
            Divider()
            Button(role: .destructive) { confirmingDiscard = true } label: {
                Label("Discard workout", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel(Text("Workout options"))
        }
    }

    private var routinePicker: some View {
        NavigationStack {
            List(session.context.plan.routines, id: \.id) { routine in
                Button {
                    model.addRoutine(routine, context: session.context)
                    showingRoutinePicker = false
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routine.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("\(routine.exercises.count) exercises")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .navigationTitle(Text("Add routine"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingRoutinePicker = false } }
            }
        }
    }

    private var physiologySource: String {
        switch model.draft.physiologyProvider ?? .none {
        case .noopBand: String(localized: "NOOP band")
        case .appleWatch: String(localized: "Apple Watch")
        case .externalTracker: model.draft.tracker?.model ?? String(localized: "Tracker")
        case .none: String(localized: "Workout continues without heart rate")
        }
    }

    private func exerciseCard(_ exerciseIndex: Int, _ exercise: NativeWorkoutExercise) -> some View {
        let definition = exercises.first { $0.id == exercise.exerciseId }
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(definition?.title ?? exercise.exerciseId).font(StrandFont.headline)
                        Text(definition?.primaryMuscleId.map(TrainingDisplayNames.muscle) ?? "")
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
                        Button("Add warm-up set") {
                            model.addWarmup(to: exercise.id, mode: definition?.mode ?? .weightReps,
                                            incrementKg: weightStep(exerciseIndex))
                        }
                        if exercise.supersetId != nil {
                            Button("Remove") {
                                if let group = exercise.supersetId {
                                    model.dissolveSuperset(group)
                                }
                            }
                        }
                        Button { model.moveExercise(exercise.id, by: -1) } label: {
                            Label("Move up", systemImage: "arrow.up")
                        }
                            .disabled(exerciseIndex == 0)
                        Button { model.moveExercise(exercise.id, by: 1) } label: {
                            Label("Move down", systemImage: "arrow.down")
                        }
                            .disabled(exerciseIndex + 1 >= model.draft.exercises.count)
                        Button("Exercise history") {
                            historyRequest = TrainingHistoryRequest(
                                id: exercise.exerciseId,
                                title: definition?.title ?? exercise.exerciseId,
                                mode: definition?.mode ?? .weightReps,
                                unilateral: definition?.isUnilateral == true)
                        }
                        if exercise.sets.contains(where: { !$0.isCompleted }) {
                            Button("Skip remaining sets") { model.skipExercise(exercise.id) }
                        }
                        Button("Change") { replacementExerciseId = exercise.id; showingExercises = true }
                        Button("Remove", role: .destructive) { model.removeExercise(exercise.id) }
                    }
                         label: {
                             Image(systemName: "ellipsis").accessibilityLabel(Text("Exercise options"))
                         }
                }
                if exercise.supersetId != nil {
                    Label("Superset", systemImage: "link")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.metricCyan)
                }
                if let definition { workoutMedia(definition, animated: exerciseIndex == model.activeExerciseIndex) }
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
                if let reason = exercise.progressionReason, let text = ProgressionReasonText.text(reason) {
                    Label(text, systemImage: "arrow.up.right")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.chargeColor)
                }
                setHeader(definition?.mode ?? .weightReps, unilateral: definition?.isUnilateral == true)
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { setIndex, set in
                    setRow(exerciseIndex, setIndex, set, mode: definition?.mode ?? .weightReps,
                           unilateral: definition?.isUnilateral == true)
                }
                Button { model.addSet(to: exercise.id) } label: { Label("Add set", systemImage: "plus") }
                    .font(StrandFont.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
                TextField("Exercise notes", text: Binding(
                    get: { exercise.note ?? "" },
                    set: { model.setExerciseNote(exercise.id, $0) }), axis: .vertical)
                    .font(StrandFont.caption)
            }
        }
    }

    private func compactExerciseCard(_ exerciseIndex: Int, _ exercise: NativeWorkoutExercise) -> some View {
        let definition = exercises.first { $0.id == exercise.exerciseId }
        let pending = exercise.sets.enumerated().filter { !$0.element.isCompleted }
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Text(definition?.title ?? exercise.exerciseId).font(StrandFont.headline)
                    Spacer()
                    Text("\(exercise.sets.filter(\.isCompleted).count)/\(exercise.sets.count)")
                        .font(StrandFont.caption.monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                }
                if let first = pending.first {
                    setRow(exerciseIndex, first.offset, first.element, mode: definition?.mode ?? .weightReps,
                           unilateral: definition?.isUnilateral == true)
                } else {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.chargeColor)
                }
            }
        }
    }

    private func previousPerformance(for exercise: NativeWorkoutExercise,
                                     mode: TrainingMeasurementMode,
                                     unilateral: Bool) -> String? {
        // The latest session that actually had working sets: a warm-up-only entry says nothing about
        // what to lift now and used to hide the useful one behind it.
        guard let entry = performance.entries(for: exercise.exerciseId).last(where: { !$0.workingSets.isEmpty })
        else { return nil }
        let sets = entry.workingSets
        let summaries = sets.prefix(4).map { previousSetSummary($0, mode: mode, unilateral: unilateral) }
        let date = Date(timeIntervalSince1970: TimeInterval(entry.startTs))
            .formatted(date: .abbreviated, time: .omitted)
        return "\(date) · \(summaries.joined(separator: ", "))"
    }

    private func previousSetSummary(_ set: TrainingPerformanceHistory.PerformedSet,
                                    mode: TrainingMeasurementMode,
                                    unilateral: Bool) -> String {
        TrainingSetText.summary(set, mode: mode, unilateral: unilateral)
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
            if effortPreference != .off { Text("EFFORT").frame(width: 50) }
            Color.clear.frame(width: 30)
        }
        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        // Column labels stay on one line in longer languages instead of breaking mid-word.
        .lineLimit(1).minimumScaleFactor(0.6)
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
            if effortPreference != .off {
                Button {
                    effortRequest = EffortPickerRequest(
                        exerciseIndex: exerciseIndex, setIndex: setIndex,
                        scale: effortPreference == .rir ? .rir : .rpe, current: set.effort)
                } label: {
                    let prefix = set.effort?.scale == .rir ? "R" : ""
                    EffortBadge(text: prefix + (set.effort?.value.formatted(.number.precision(.fractionLength(0...1))) ?? "—"),
                                color: set.effort.map { EffortChoice.color(for: $0) })
                        .frame(width: 50, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(effortPreference == .rir ? "Repetitions in reserve" : "RPE"))
                .accessibilityValue(Text(set.effort.map { $0.value.formatted(.number.precision(.fractionLength(0...1))) }
                                         ?? String(localized: "Not rated")))
            }
            Button {
                model.toggleSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
                setCompletionHaptic()
            } label: {
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(set.isCompleted ? StrandPalette.chargeColor : StrandPalette.textTertiary)
            }.buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(set.isCompleted ? "Mark set incomplete" : "Mark set complete"))
        }
        .padding(.vertical, 4)
        .opacity(set.isCompleted ? 0.72 : 1)
        // A container keeps every control reachable; combining the row would hide them behind one label.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(setAccessibilityLabel(set, mode: mode, unilateral: unilateral))
    }

    /// The exercise's animation above its sets. Only the exercise being logged animates; the others
    /// show a still, so a list of exercises never decodes several animations at once.
    @ViewBuilder private func workoutMedia(_ exercise: TrainingExercise, animated: Bool) -> some View {
        let presentation = TrainingMediaPresentation(rawValue: mediaPresentationRaw) ?? .large
        if presentation != .hidden, media.isAvailable,
           let item = ExerciseMediaRegistry.shared.media(for: exercise, variant: animated ? .animation : .still) {
            VStack(alignment: .trailing, spacing: 2) {
                ExerciseMediaView(media: item,
                                  minHeight: presentation == .large ? 180 : 80,
                                  maxHeight: presentation == .large ? 260 : 110)
                    .accessibilityLabel(String(localized: "Exercise demonstration for \(exercise.title)"))
                Text(ExerciseMediaStore.Provider.displayCredit)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func setCompletionHaptic() {
        guard hapticsEnabled else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    private func timerFinishedFeedback() {
        guard hapticsEnabled, TrainingPreferences.timerFeedbackEnabled else { return }
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private func setAccessibilityLabel(_ set: NativeWorkoutSet,
                                       mode: TrainingMeasurementMode,
                                       unilateral: Bool) -> String {
        let phase = set.phase == .warmup ? String(localized: "Warm-up") : String(localized: "Working set")
        let result = previousSetSummary(.init(set), mode: mode, unilateral: unilateral)
        let effort = set.effort.map { "\($0.scale == .rir ? "RIR" : "RPE") \($0.value.formatted())" }
        return [phase, result, effort, set.isCompleted ? String(localized: "Complete") : String(localized: "Incomplete")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder private func metricControls(_ exerciseIndex: Int, _ setIndex: Int,
                                             _ set: NativeWorkoutSet,
                                             mode: TrainingMeasurementMode,
                                             unilateral: Bool) -> some View {
        switch mode {
        case .weightReps, .weightedBodyweight, .assistedBodyweight:
            let step = weightStep(exerciseIndex)
            let field = TrainingSetField(setId: set.id, metric: .weight)
            stepControl(mode == .assistedBodyweight ? String(localized: "Assistance in kilograms")
                            : String(localized: "Weight in kilograms"),
                        value: set.weightKg.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "—",
                        field: field,
                        minus: { model.adjustWeight(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -step) },
                        plus: { model.adjustWeight(exerciseIndex: exerciseIndex, setIndex: setIndex, by: step) }) {
                decimalField(set.weightKg, field: field) {
                    model.setWeight(exerciseIndex: exerciseIndex, setIndex: setIndex, kg: $0)
                }
            }
            repsControls(exerciseIndex, setIndex, set, unilateral: unilateral)
        case .bodyweightReps, .repetitions:
            repsControls(exerciseIndex, setIndex, set, unilateral: unilateral)
        case .duration:
            stepControl(String(localized: "Duration"), value: durationText(set.durationS), field: nil,
                        minus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -5) },
                        plus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 5) }) {
                Text(durationText(set.durationS)).font(StrandFont.subhead.monospacedDigit())
            }
            Button { model.startTimedSet(exerciseIndex: exerciseIndex, setIndex: setIndex) } label: {
                Image(systemName: "timer")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Start timed set"))
        case .distanceDuration:
            let field = TrainingSetField(setId: set.id, metric: .distance)
            stepControl(String(localized: "Distance in meters"),
                        value: set.distanceM.map { "\(Int($0.rounded())) m" } ?? "—", field: field,
                        minus: { model.adjustDistance(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -10) },
                        plus: { model.adjustDistance(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 10) }) {
                decimalField(set.distanceM, field: field) {
                    model.setDistance(exerciseIndex: exerciseIndex, setIndex: setIndex, meters: $0)
                }
            }
            stepControl(String(localized: "Duration"), value: durationText(set.durationS), field: nil,
                        minus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -5) },
                        plus: { model.adjustDuration(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 5) }) {
                Text(durationText(set.durationS)).font(StrandFont.subhead.monospacedDigit())
            }
        }
    }

    private func repsControl(_ exerciseIndex: Int, _ setIndex: Int,
                             _ set: NativeWorkoutSet) -> some View {
        let field = TrainingSetField(setId: set.id, metric: .reps)
        return stepControl(String(localized: "Repetitions"), value: set.reps.map(String.init) ?? "—",
                           field: field,
                           minus: { model.adjustReps(exerciseIndex: exerciseIndex, setIndex: setIndex, by: -1) },
                           plus: { model.adjustReps(exerciseIndex: exerciseIndex, setIndex: setIndex, by: 1) }) {
            integerField(set.reps, field: field) {
                model.setReps(exerciseIndex: exerciseIndex, setIndex: setIndex, reps: $0)
            }
        }
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
        let field = TrainingSetField(setId: set.id, metric: left ? .leftReps : .rightReps)
        return stepControl(left ? String(localized: "Left repetitions") : String(localized: "Right repetitions"),
                           value: value.map(String.init) ?? "—", field: field,
                           minus: { model.adjustSideReps(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                                         left: left, by: -1) },
                           plus: { model.adjustSideReps(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                                        left: left, by: 1) }) {
            integerField(value, field: field) {
                model.setSideReps(exerciseIndex: exerciseIndex, setIndex: setIndex, left: left, reps: $0)
            }
        }
    }

    private func weightStep(_ exerciseIndex: Int) -> Double {
        guard model.draft.exercises.indices.contains(exerciseIndex) else {
            return TrainingPreferences.weightStep(for: [])
        }
        let entry = model.draft.exercises[exerciseIndex]
        let equipment = entry.equipmentSnapshot?.equipmentIds
            ?? exercises.first { $0.id == entry.exerciseId }?.equipmentIds ?? []
        return TrainingPreferences.weightStep(for: equipment)
    }

    /// Typed entry commits when the field loses focus or the keyboard's Done button is pressed; the
    /// number format follows the reader's locale, including its decimal separator.
    private func decimalField(_ value: Double?, field: TrainingSetField,
                              onCommit: @escaping (Double?) -> Void) -> some View {
        TextField("—", value: Binding(get: { value }, set: { onCommit($0) }),
                  format: .number.precision(.fractionLength(0...2)))
            .trainingNumberKeyboard(decimal: true)
            .focused($focusedSetField, equals: field)
            .multilineTextAlignment(.center)
            .font(StrandFont.subhead.monospacedDigit())
    }

    private func integerField(_ value: Int?, field: TrainingSetField,
                              onCommit: @escaping (Int?) -> Void) -> some View {
        TextField("—", value: Binding(get: { value }, set: { onCommit($0) }), format: .number)
            .trainingNumberKeyboard(decimal: false)
            .focused($focusedSetField, equals: field)
            .multilineTextAlignment(.center)
            .font(StrandFont.subhead.monospacedDigit())
    }

    private func setKindMenu(_ exerciseIndex: Int, _ setIndex: Int,
                             _ set: NativeWorkoutSet) -> some View {
        Menu {
            Button("Working set") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                                   phase: .work, intensifier: .none) }
            Button("Warm-up") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                              phase: .warmup, intensifier: .none) }
            Divider()
            if set.phase == .work && set.parentSetId == nil {
                Button("Drop set") { model.addTechniqueSegment(exerciseIndex: exerciseIndex,
                    setIndex: setIndex, intensifier: .dropSet) }
                Button("Rest-pause") { model.addTechniqueSegment(exerciseIndex: exerciseIndex,
                    setIndex: setIndex, intensifier: .restPause) }
            }
            Button("AMRAP") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                            phase: .work, intensifier: .amrap) }
            Button("To failure") { model.setKind(exerciseIndex: exerciseIndex, setIndex: setIndex,
                                                 phase: .work, intensifier: .failure) }
            Divider()
            Button("Duplicate set") {
                model.duplicateSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
            }
            Button("Remove this set", role: .destructive) {
                model.removeSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
            }
        } label: {
            Text(setLabel(set, index: setIndex)).font(StrandFont.subhead.weight(.semibold)).frame(width: 36)
        }
        .accessibilityLabel(Text("Set \(setIndex + 1) options"))
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

    /// One adjustable element for VoiceOver: swiping up or down runs the same step as the buttons, and a
    /// named action focuses typed entry. Sighted users tap the value to type it directly.
    private func stepControl<Editor: View>(_ title: String, value: String, field: TrainingSetField?,
                                           minus: @escaping () -> Void, plus: @escaping () -> Void,
                                           @ViewBuilder editor: () -> Editor) -> some View {
        HStack(spacing: 2) {
            Button(action: minus) {
                Image(systemName: "minus").frame(minWidth: 26, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            editor().frame(minWidth: 32, maxWidth: .infinity)
            Button(action: plus) {
                Image(systemName: "plus").frame(minWidth: 26, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: plus()
            case .decrement: minus()
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Enter value")) {
            if let field { focusedSetField = field }
        }
    }

    // How demanding the WHOLE session felt only means something once it's over — that question is
    // asked post-workout by `SessionRPECard`, already wired into `StrengthWorkoutSummaryView` below,
    // with its own reminder if it's skipped there. Asking it again mid-session would be a second,
    // unsynced answer to the same question, so this card is notes only while the workout is running.
    private var noteCard: some View {
        NoopCard {
            TextField("Workout notes", text: Binding(
                get: { model.draft.note ?? "" },
                set: { model.setWorkoutNote($0) }), axis: .vertical)
        }
    }

    private func requestFinish() {
        let validation = NativeWorkoutEngine.completionValidation(for: model.draft)
        if validation.state == .partial {
            confirmingPartialFinish = true
        } else {
            finishNow()
        }
    }

    private func finishNow() {
        Task {
            if let workout = await model.finish() {
                session.strengthFinished(workout)
            }
        }
    }

    /// Closes the logger only once the draft is actually gone; a failed delete leaves the session open
    /// with its own error rather than dropping the wearer back into a hub that still has the workout.
    private func discardNow() {
        Task {
            if await model.discard() {
                session.strengthDiscarded()
            }
        }
    }

    /// The one exercise library, in the mode this sheet was opened for: adding to the session or swapping
    /// an exercise that is already in it.
    private var exercisePicker: some View {
        NavigationStack {
            TrainingExerciseLibraryView(
                exercises: session.context.exercises.isEmpty ? exercises : session.context.exercises,
                performance: performance,
                mode: replacementExerciseId == nil ? .addToWorkout : .replace,
                onPick: { exercise in
                    if let replacementExerciseId {
                        model.replaceExercise(replacementExerciseId, with: exercise)
                        self.replacementExerciseId = nil
                    } else {
                        model.addExercise(exercise)
                    }
                    showingExercises = false
                },
                onSave: { exercise in Task { await session.saveExercise(exercise) } })
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

/// One line of measured work, in the units the movement is logged in. The summary, the workout
/// detail, the logger's "last time" line and the in-workout history read the same function, so the
/// same set can never be written three different ways.
private enum TrainingSetText {
    static func summary(_ set: TrainingPerformanceHistory.PerformedSet,
                        mode: TrainingMeasurementMode, unilateral: Bool) -> String {
        let reps = repetitions(set, unilateral: unilateral)
        switch mode {
        case .weightReps: return "\(weight(set.weightKg)) kg × \(reps)"
        case .weightedBodyweight: return "+\(weight(set.weightKg)) kg × \(reps)"
        case .assistedBodyweight: return "−\(weight(set.weightKg)) kg × \(reps)"
        case .bodyweightReps, .repetitions: return String(localized: "\(reps) reps")
        case .duration: return duration(set.durationS)
        case .distanceDuration: return "\(weight(set.distanceM)) m · \(duration(set.durationS))"
        }
    }

    static func repetitions(_ set: TrainingPerformanceHistory.PerformedSet, unilateral: Bool) -> String {
        guard unilateral else { return set.reps.map { $0.formatted() } ?? "—" }
        let left = set.leftReps.map { $0.formatted() } ?? "—"
        let right = set.rightReps.map { $0.formatted() } ?? "—"
        return "L \(left) · R \(right)"
    }

    static func effort(_ rating: TrainingEffortRating) -> String {
        let value = rating.value.formatted(.number.precision(.fractionLength(0...1)))
        return rating.scale == .rir ? "RIR \(value)" : "RPE \(value)"
    }

    static func weight(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...2))) ?? "—"
    }

    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct TrainingHistoryRequest: Identifiable {
    let id: String
    let title: String
    let mode: TrainingMeasurementMode
    let unilateral: Bool
}

/// Earlier sessions of one exercise, readable without leaving the running workout.
private struct TrainingExerciseHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let mode: TrainingMeasurementMode
    let unilateral: Bool
    let entries: [TrainingPerformanceHistory.Entry]

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No earlier sessions of this exercise yet.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Section {
                    ForEach(Array(entry.workingSets.enumerated()), id: \.offset) { index, set in
                        HStack(spacing: 8) {
                            Text((index + 1).formatted())
                                .font(StrandFont.caption.weight(.bold)).frame(width: 22)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text(TrainingSetText.summary(set, mode: mode, unilateral: unilateral))
                                .font(StrandFont.subhead.monospacedDigit())
                            Spacer()
                            if let effort = set.effort {
                                Text(TrainingSetText.effort(effort))
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    HStack {
                        Text(Date(timeIntervalSince1970: TimeInterval(entry.startTs)), style: .date)
                        if !entry.isNative { Text("Imported") }
                    }
                }
            }
        }
        .navigationTitle(Text(title))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct TrainingSetField: Hashable {
    enum Metric: Hashable { case weight, reps, leftReps, rightReps, distance }
    let setId: UUID
    let metric: Metric
}

private extension View {
    @ViewBuilder
    func trainingNumberKeyboard(decimal: Bool) -> some View {
        #if os(iOS)
        keyboardType(decimal ? .decimalPad : .numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func trainingKeyboardDoneButton(_ action: @escaping () -> Void) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: action)
            }
        }
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

/// The routine list's "Add" actions, in the same sheet presentation as editing a routine — replaces a
/// `Menu` popup so the two interactions feel like one component instead of two.
private struct AddRoutineActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onLibrary: () -> Void
    let onAddRoutine: () -> Void
    let onShare: () -> Void
    let onExportPDF: () -> Void
    let onImportPlan: () -> Void
    let onImportHistory: () -> Void
    let onLogPastWorkout: () -> Void

    var body: some View {
        List {
            Section {
                actionRow("Exercise library", systemImage: "books.vertical", action: onLibrary)
                actionRow("Add routine", systemImage: "plus.rectangle.on.rectangle", action: onAddRoutine)
            }
            Section("Import & export") {
                actionRow("Share training plan", systemImage: "square.and.arrow.up", action: onShare)
                actionRow("Export plan as PDF", systemImage: "doc.richtext", action: onExportPDF)
                actionRow("Import training plan", systemImage: "square.and.arrow.down", action: onImportPlan)
                actionRow("Import FitNotes or Strong history", systemImage: "clock.arrow.circlepath",
                          action: onImportHistory)
                actionRow("Log past workout", systemImage: "calendar.badge.clock", action: onLogPastWorkout)
            }
        }
        .navigationTitle(Text("Add"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func actionRow(_ title: LocalizedStringKey, systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// One routine's actions, in the same sheet presentation as editing it — replaces the "⋯" `Menu` popup.
private struct RoutineActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let routine: TrainingRoutine
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void

    var body: some View {
        List {
            Button { dismiss(); onPreview() } label: { Label("Preview", systemImage: "eye") }
            Button { dismiss(); onEdit() } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            Button { dismiss(); onDuplicate() } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        .navigationTitle(Text(routine.title))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

private struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var routine: TrainingRoutine
    @State var weekdays: Set<TrainingWeekday>
    let exercises: [TrainingExercise]
    let onSave: (TrainingRoutine, Set<TrainingWeekday>) -> Void
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
            Section {
                let muscles = TrainingMuscleProjection.routine(routine, exercises: exerciseById)
                if muscles.isEmpty {
                    Text("Muscle distribution becomes available after exercises are mapped.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    HStack(spacing: NoopMetrics.space3) {
                        TrainingMiniMusclePreview(values: muscles)
                        Text(TrainingRoutineMuscles.topNames(muscles).joined(separator: " · "))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Muscle preview")
            } footer: {
                Text("The preview uses the same muscle mapping as completed-workout analytics.")
            }
            Section {
                ForEach(TrainingWeekday.allCases, id: \.rawValue) { weekday in
                    Toggle(weekday.title, isOn: Binding(
                        get: { weekdays.contains(weekday) },
                        set: { enabled in
                            if enabled { weekdays.insert(weekday) } else { weekdays.remove(weekday) }
                        }))
                }
            } header: {
                Text("Scheduled days")
            } footer: {
                Text("Other routines planned on the same days stay in place. A one-day change in the week view still takes priority.")
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
                        if routine.exercises[index].supersetId != nil {
                            Button("Remove superset") {
                                routine.exercises[index].supersetId = nil
                                cleanSupersets()
                            }.tint(StrandPalette.textSecondary)
                        }
                    }
                }
                .onDelete { routine.exercises.remove(atOffsets: $0); cleanSupersets() }
                .onMove { RoutineEditing.move(&routine.exercises, from: $0, to: $1) }
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
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { routine.updatedAt = Int(Date().timeIntervalSince1970); onSave(routine, weekdays); dismiss() }
                    .disabled(routine.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: $showingExercises) {
            NavigationStack {
                TrainingExerciseLibraryView(exercises: exercises, mode: .addToRoutine, onPick: { exercise in
                    routine.exercises.append(.init(exerciseId: exercise.id,
                        sets: (0..<3).map { _ in .init(repsMin: 8, repsMax: 12) }))
                    showingExercises = false
                })
            }
        }
        .confirmationDialog("Delete this routine?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) { onDelete(routine.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed workouts stay in your history.")
        }
    }

    private var exerciseById: [String: TrainingExercise] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

/// Names the most involved muscles of a planned routine for compact previews.
private enum TrainingRoutineMuscles {
    static func topNames(_ values: [String: Double], limit: Int = 5) -> [String] {
        values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { item in TrainingDisplayNames.muscle(item.key) }
    }
}

private struct TrainingRoutinePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let routine: TrainingRoutine
    let exercises: [String: TrainingExercise]
    let weekdays: Set<TrainingWeekday>
    let onStart: () -> Void

    private var scheduledDays: String {
        let symbols = Calendar.current.standaloneWeekdaySymbols
        return TrainingWeekday.allCases.filter(weekdays.contains)
            .map { symbols[$0.rawValue % 7] }
            .formatted(.list(type: .and))
    }

    var body: some View {
        List {
            let muscles = TrainingMuscleProjection.routine(routine, exercises: exercises)
            if !muscles.isEmpty || !weekdays.isEmpty {
                Section {
                    if !muscles.isEmpty {
                        HStack(spacing: NoopMetrics.space3) {
                            TrainingMiniMusclePreview(values: muscles)
                            Text(TrainingRoutineMuscles.topNames(muscles).joined(separator: " · "))
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if !weekdays.isEmpty {
                        Label {
                            Text(scheduledDays)
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                } header: {
                    Text("Muscle preview")
                }
            }
            Section {
                ForEach(Array(routine.exercises.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        Text((index + 1).formatted())
                            .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercises[entry.exerciseId]?.title ?? entry.exerciseId)
                                .font(StrandFont.headline)
                            Text("\(entry.sets.filter { $0.phase == .work }.count) working sets · \(entry.restSeconds) sec rest")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            if entry.sets.contains(where: { $0.phase == .warmup }) {
                                Text("Includes warm-up sets")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.metricCyan)
                            }
                            if entry.supersetId != nil {
                                Label("Superset", systemImage: "link")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.metricCyan)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Workout preview")
            } footer: {
                let values = TrainingMuscleProjection.routine(routine, exercises: exercises)
                Text(values.isEmpty
                     ? String(localized: "Muscle distribution becomes available after exercises are mapped.")
                     : String(localized: "The preview uses the same muscle mapping as completed-workout analytics."))
            }
        }
        .navigationTitle(routine.title)
        .safeAreaInset(edge: .bottom) {
            Button {
                dismiss()
                onStart()
            } label: {
                Label("Start workout", systemImage: "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
            .padding(NoopMetrics.screenPadding)
            .background(.ultraThinMaterial)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
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
                // nil follows the routine default; an explicit `.off` disables progression for this exercise.
                Picker("Method", selection: Binding<ProgressionPolicy?>(
                    get: { entry.progression?.policy },
                    set: { value in entry.progression = value.map { ProgressionConfiguration(policy: $0) } })) {
                    Text("Use routine default").tag(ProgressionPolicy?.none)
                    Text("Off").tag(ProgressionPolicy?.some(.off))
                    Text("Linear").tag(ProgressionPolicy?.some(.linear))
                    Text("Double progression").tag(ProgressionPolicy?.some(.doubleProgression))
                    Text("Greyskull LP").tag(ProgressionPolicy?.some(.greyskullLP))
                    Text("Time progression").tag(ProgressionPolicy?.some(.time))
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
