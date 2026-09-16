import Foundation
import Combine
import StrandDesign
import StrandTraining
import UserNotifications

@MainActor
final class TrainingHubModel: ObservableObject {
    struct HistoryImportPreview: Identifiable {
        let id = UUID()
        let result: TrainingHistoryImport
        let mappedExerciseCount: Int

        var workoutCount: Int { result.workouts.count }
        var exerciseCount: Int { Set(result.workouts.flatMap { $0.exercises.map(\.exerciseId) }).count }
        var setCount: Int { result.workouts.flatMap(\.exercises).flatMap(\.sets).count }
    }

    @Published private(set) var loaded = false
    @Published private(set) var exercises: [TrainingExercise] = []
    @Published private(set) var plan = TrainingPlan()
    @Published private(set) var workouts: [NativeWorkout] = []
    @Published private(set) var resolvedHistory = ResolvedStrengthHistory(
        sessions: [], workouts: [], templates: [:])
    @Published private(set) var trackers: [SessionTrackerAttribution] = []
    @Published private(set) var performanceHistory = TrainingPerformanceHistory.empty
    @Published var draft: WorkoutDraft?
    @Published var historyImportPreview: HistoryImportPreview?
    @Published var errorMessage: String?

    func load(repo: Repository, weekStartsOn: TrainingWeekStart = .monday) async {
        await repo.prepareNativeTraining()
        async let exercises = repo.nativeTrainingExercises()
        async let plan = repo.nativeTrainingPlan(weekStartsOn: weekStartsOn)
        async let workouts = repo.nativeWorkouts()
        async let trackers = repo.nativeTrainingTrackers()
        async let draft = repo.nativeWorkoutDraft()
        async let resolved = repo.resolvedStrengthHistory(days: ResolvedStrengthHistory.allHistoryDays)
        self.exercises = await exercises
        self.plan = await plan
        self.workouts = await workouts
        self.trackers = await trackers
        self.draft = await draft
        self.resolvedHistory = await resolved
        refreshPerformanceHistory()
        loaded = true
    }

    private func refreshPerformanceHistory() {
        performanceHistory = TrainingPerformanceHistory(native: workouts, resolved: resolvedHistory,
                                                        exercises: exercises)
    }

    var exerciseById: [String: TrainingExercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    func routines(on date: Date) -> [TrainingRoutine] {
        let day = Self.dayFormatter.string(from: date)
        let weekday = TrainingWeekday(rawValue: Calendar.current.component(.weekday, from: date) == 1
            ? 7 : Calendar.current.component(.weekday, from: date) - 1) ?? .monday
        return plan.routines(day: day, weekday: weekday)
    }

    func start(routines: [TrainingRoutine], tracker: SessionTrackerAttribution?, repo: Repository,
               date: Date = Date(), pastDurationS: Int? = nil) async {
        let now = Int(date.timeIntervalSince1970)
        let day = Self.dayFormatter.string(from: date)
        let title = routines.isEmpty ? String(localized: "Freestyle workout")
            : routines.map(\.title).joined(separator: " + ")
        let value = NativeWorkoutEngine.draft(title: title, day: day, startTs: now,
                                               routines: routines, tracker: tracker,
                                               exerciseDefinitions: exerciseById)
        var prepared = value
        normalizeUnilateralSets(in: &prepared)
        if let pastDurationS { prepared.plannedEndTs = now + max(60, pastDurationS) }
        NativeWorkoutEngine.prefillLastPerformance(&prepared, history: workouts)
        performanceHistory.prefillImported(&prepared)
        applyProgression(to: &prepared, routines: routines)
        do {
            try await repo.saveNativeWorkoutDraft(prepared)
            draft = prepared
        } catch {
            errorMessage = String(localized: "The workout could not be started.")
        }
    }

    func addStarter(_ routine: TrainingRoutine, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingRoutine(routine)
            plan = await repo.nativeTrainingPlan()
        } catch {
            errorMessage = String(localized: "The routine could not be saved.")
        }
    }

    func saveExercise(_ exercise: TrainingExercise, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingExercise(exercise)
            exercises = await repo.nativeTrainingExercises()
            refreshPerformanceHistory()
        } catch {
            errorMessage = String(localized: "The exercise could not be saved.")
        }
    }

    /// Appends an exercise to the running draft, so the library can be used mid-workout without
    /// leaving it. The logger owns the draft while it is open; this path is for the hub's library.
    func addExerciseToDraft(_ exercise: TrainingExercise, repo: Repository) async {
        guard var current = draft else { return }
        let initial = exercise.isUnilateral
            ? NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0,
                               leftReps: 8, rightReps: 8)
            : NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0, reps: 8)
        NativeWorkoutEngine.addExercise(exercise.id, to: &current, sets: [initial], definition: exercise)
        do {
            try await repo.saveNativeWorkoutDraft(current)
            draft = current
        } catch {
            errorMessage = String(localized: "The exercise could not be added to the workout.")
        }
    }

    func saveRoutine(_ routine: TrainingRoutine, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingRoutine(routine)
            plan = await repo.nativeTrainingPlan(weekStartsOn: plan.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The routine could not be saved.")
        }
    }

    /// Saves the routine, then its weekday assignment. Other routines keep their days and order.
    func saveRoutine(_ routine: TrainingRoutine, weekdays: Set<TrainingWeekday>, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingRoutine(routine)
            let schedule = RoutineEditing.schedule(plan.schedule, assigning: routine.id, to: weekdays)
            if schedule != plan.schedule { try await repo.saveNativeTrainingSchedule(schedule) }
            plan = await repo.nativeTrainingPlan(weekStartsOn: plan.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The routine could not be saved.")
        }
    }

    func duplicateRoutine(_ routine: TrainingRoutine, repo: Repository) async {
        let copy = RoutineEditing.duplicate(
            routine, title: String(localized: "\(routine.title) copy"),
            now: Int(Date().timeIntervalSince1970))
        await saveRoutine(copy, repo: repo)
    }

    func deleteRoutine(_ id: UUID, repo: Repository) async {
        do {
            try await repo.deleteNativeTrainingRoutine(id)
            plan = await repo.nativeTrainingPlan(weekStartsOn: plan.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The routine could not be deleted.")
        }
    }

    func planArchiveData() throws -> Data {
        try TrainingPlanArchive(plan: plan, exercises: exercises).encoded()
    }

    func importPlan(_ data: Data, repo: Repository) async {
        do {
            let archive = try TrainingPlanArchive.decode(data)
            try await repo.importNativeTrainingPlan(archive)
            await load(repo: repo, weekStartsOn: archive.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The training plan could not be imported.")
        }
    }

    func prepareHistoryImport(_ data: Data) {
        do {
            let result = try TrainingCSVImporter.parse(data, existingExercises: exercises)
            let definitions = Dictionary(uniqueKeysWithValues:
                (exercises + result.exercises).map { ($0.id, $0) })
            let used = Set(result.workouts.flatMap { $0.exercises.map(\.exerciseId) })
            let mapped = used.filter { id in
                definitions[id].map { TrainingMuscleProjection.anatomy(for: $0) != nil } ?? false
            }.count
            historyImportPreview = .init(result: result, mappedExerciseCount: mapped)
        } catch {
            errorMessage = String(localized: "The workout history could not be imported.")
        }
    }

    func confirmHistoryImport(repo: Repository) async {
        guard let preview = historyImportPreview else { return }
        do {
            try await repo.importNativeTrainingHistory(preview.result)
            historyImportPreview = nil
            await load(repo: repo)
            errorMessage = preview.result.skippedRows > 0
                ? String(localized: "The history was imported. Some incomplete rows were skipped.") : nil
        } catch {
            errorMessage = String(localized: "The workout history could not be imported.")
        }
    }

    func saveSchedule(_ schedule: [TrainingWeekday: [UUID]], repo: Repository) async {
        do {
            try await repo.saveNativeTrainingSchedule(schedule)
            plan = await repo.nativeTrainingPlan(weekStartsOn: plan.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The schedule could not be saved.")
        }
    }

    func saveOverride(_ override: TrainingDayOverride, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingOverride(override)
            plan = await repo.nativeTrainingPlan(weekStartsOn: plan.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The day could not be changed.")
        }
    }

    func clearOverride(day: String, repo: Repository) async {
        do {
            try await repo.deleteNativeTrainingOverride(day: day)
            plan = await repo.nativeTrainingPlan(weekStartsOn: plan.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The day could not be reset.")
        }
    }

    func workoutFinished(repo: Repository) async {
        await closeSession(repo: repo)
    }

    /// The logger threw the session away. The reload is the same as a finish's; the difference is that
    /// nothing reached history, so the hub simply has no workout in progress any more.
    func workoutDiscarded(repo: Repository) async {
        await closeSession(repo: repo)
    }

    private func closeSession(repo: Repository) async {
        draft = nil
        await load(repo: repo, weekStartsOn: plan.weekStartsOn)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func weekday(_ date: Date) -> TrainingWeekday {
        let value = Calendar.current.component(.weekday, from: date)
        return TrainingWeekday(rawValue: value == 1 ? 7 : value - 1) ?? .monday
    }

    private func applyProgression(to draft: inout WorkoutDraft, routines: [TrainingRoutine]) {
        let routineExercises = routines.flatMap { routine in
            routine.exercises.map { ($0.id, $0, routine.defaultProgression) }
        }
        let byRoutineExercise = Dictionary(uniqueKeysWithValues: routineExercises.map { ($0.0, ($0.1, $0.2)) })
        let exerciseDefinitions = exerciseById
        for index in draft.exercises.indices {
            guard !draft.exercises[index].excludeFromProgression,
                  let routineId = draft.exercises[index].routineId,
                  let planned = routines.first(where: { $0.id == routineId })?.exercises
                    .first(where: { $0.exerciseId == draft.exercises[index].exerciseId }),
                  let definition = exerciseDefinitions[draft.exercises[index].exerciseId] else { continue }
            let configuration = planned.progression
                ?? byRoutineExercise[planned.id]?.1
                ?? ProgressionConfiguration()
            // Native and imported sessions of the same reviewed exercise, oldest first, each counted once.
            let history = performanceHistory.entries(for: planned.exerciseId).compactMap { entry -> ProgressionSession? in
                let work = entry.workingSets
                guard !work.isEmpty else { return nil }
                let reps = work.compactMap(\.completedReps)
                return ProgressionSession(
                    weightKg: work.compactMap(\.weightKg).max(),
                    completedReps: reps,
                    targetReps: Array(repeating: configuration.repsMin, count: reps.count),
                    durationS: work.compactMap(\.durationS).max(),
                    targetDurationS: planned.sets.compactMap(\.targetDurationS).max(),
                    workSetCount: work.count,
                    efforts: work.compactMap(\.effort))
            }
            let currentWork = draft.exercises[index].sets.filter { $0.phase == .work }
            let next = TrainingProgressionEngine.next(
                configuration: configuration, history: history, mode: definition.mode,
                currentWeightKg: currentWork.compactMap(\.weightKg).max(),
                currentReps: currentWork.compactMap(Self.completedReps).min(),
                currentSets: currentWork.count,
                currentDurationS: currentWork.compactMap(\.durationS).max())
            for setIndex in draft.exercises[index].sets.indices
                where draft.exercises[index].sets[setIndex].phase == .work {
                if let weight = next.weightKg { draft.exercises[index].sets[setIndex].weightKg = weight }
                if let reps = next.reps {
                    if definition.isUnilateral {
                        draft.exercises[index].sets[setIndex].leftReps = reps
                        draft.exercises[index].sets[setIndex].rightReps = reps
                        draft.exercises[index].sets[setIndex].reps = nil
                    } else {
                        draft.exercises[index].sets[setIndex].reps = reps
                    }
                }
                if let duration = next.durationS { draft.exercises[index].sets[setIndex].durationS = duration }
            }
            if let count = next.setCount, count > currentWork.count {
                let template = draft.exercises[index].sets.last(where: { $0.phase == .work })
                    ?? NativeWorkoutSet(index: draft.exercises[index].sets.count)
                while draft.exercises[index].sets.filter({ $0.phase == .work }).count < count {
                    var added = template
                    added = NativeWorkoutSet(index: draft.exercises[index].sets.count,
                        phase: .work, intensifier: added.intensifier, weightKg: added.weightKg,
                        reps: added.reps, leftReps: added.leftReps, rightReps: added.rightReps,
                        durationS: added.durationS, distanceM: added.distanceM)
                    draft.exercises[index].sets.append(added)
                }
            }
        }
    }

    private func normalizeUnilateralSets(in draft: inout WorkoutDraft) {
        let definitions = exerciseById
        for exerciseIndex in draft.exercises.indices {
            guard definitions[draft.exercises[exerciseIndex].exerciseId]?.isUnilateral == true else { continue }
            for setIndex in draft.exercises[exerciseIndex].sets.indices {
                let shared = draft.exercises[exerciseIndex].sets[setIndex].reps
                if draft.exercises[exerciseIndex].sets[setIndex].leftReps == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].leftReps = shared
                }
                if draft.exercises[exerciseIndex].sets[setIndex].rightReps == nil {
                    draft.exercises[exerciseIndex].sets[setIndex].rightReps = shared
                }
                draft.exercises[exerciseIndex].sets[setIndex].reps = nil
            }
        }
    }

    private static func completedReps(_ set: NativeWorkoutSet) -> Int? {
        if let reps = set.reps { return reps }
        if let left = set.leftReps, let right = set.rightReps { return min(left, right) }
        return set.leftReps ?? set.rightReps
    }
}

@MainActor
final class NativeWorkoutSessionModel: ObservableObject {
    @Published var draft: WorkoutDraft
    @Published var sessionRPE: Double?
    @Published var errorMessage: String?
    @Published private(set) var liveBPM: Int?
    @Published var watchFinishRequested = false

    private let repo: Repository
    private let app: AppModel
    private let coordinator: StrengthWorkoutCoordinator
    private let exerciseTitles: [String: String]
    private var cancellables: Set<AnyCancellable> = []
    private var pendingPersist: Task<Void, Never>?
    private var discarded = false

    init(draft: WorkoutDraft, repo: Repository, app: AppModel,
         exercises: [TrainingExercise]) {
        self.draft = draft
        self.repo = repo
        self.app = app
        self.coordinator = StrengthWorkoutCoordinator(app: app)
        self.exerciseTitles = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.title) })
        coordinator.beginOrResume(&self.draft)
        liveBPM = coordinator.liveBPM
        app.$bpm.sink { [weak self] bpm in
            guard let self, self.draft.physiologyProvider != .appleWatch else { return }
            self.liveBPM = self.app.activeWorkout == nil ? nil : bpm
        }.store(in: &cancellables)
        coordinator.onTelemetry = { [weak self] bpm in
            self?.liveBPM = bpm
            self?.publishCompanionState()
        }
        coordinator.onWatchCommand = { [weak self] command in self?.handleWatchCommand(command) }
        touchAndPersist()
    }

    var activeTimer: WorkoutTimerState? { draft.timer }

    var activeExerciseIndex: Int {
        guard let id = draft.cursor?.exerciseId,
              let index = draft.exercises.firstIndex(where: { $0.id == id }) else { return 0 }
        return index
    }

    func selectExercise(at index: Int) {
        guard draft.exercises.indices.contains(index) else { return }
        draft.cursor = .init(exerciseId: draft.exercises[index].id,
                             setId: draft.exercises[index].sets.first(where: { !$0.isCompleted })?.id)
        touchAndPersist()
    }

    func toggleWorkoutPause() {
        if draft.state == .active { coordinator.pause(&draft) }
        else { coordinator.resume(&draft) }
        touchAndPersist()
    }

    func appMovedToBackground() {
        guard draft.state == .active else { return }
        draft.interruptionReason = .appBackgrounded
        touchAndPersist()
    }

    func appReturnedToForeground() {
        guard draft.state == .active, draft.interruptionReason == .appBackgrounded else { return }
        draft.interruptionReason = nil
        touchAndPersist()
    }

    func addExercise(_ exercise: TrainingExercise) {
        let initial = exercise.isUnilateral
            ? NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0,
                               leftReps: 8, rightReps: 8)
            : NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0,
                               reps: 8)
        NativeWorkoutEngine.addExercise(exercise.id, to: &draft,
            sets: [initial], definition: exercise)
        if let index = draft.exercises.indices.last {
            draft.exercises[index].restSeconds = UserDefaults.standard.object(
                forKey: TrainingPreferences.defaultRestKey) as? Int
                ?? TrainingPreferences.defaultRestSeconds
            draft.exercises[index].warmupRestSeconds = UserDefaults.standard.object(
                forKey: TrainingPreferences.warmupRestKey) as? Int
                ?? TrainingPreferences.defaultWarmupRestSeconds
        }
        touchAndPersist()
    }

    func addSet(to exerciseId: UUID) {
        try? NativeWorkoutEngine.appendSet(to: exerciseId, in: &draft)
        touchAndPersist()
    }

    func addWarmup(to exerciseId: UUID, mode: TrainingMeasurementMode, incrementKg: Double = 2.5) {
        guard let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        let exercise = draft.exercises[exerciseIndex]
        let firstWork = exercise.sets.first(where: { $0.phase == .work })
        let suggestions = WarmupPlanner.suggestedSets(firstWorkSetKg: firstWork?.weightKg, mode: mode,
                                                       incrementKg: incrementKg, count: 3)
        guard !suggestions.isEmpty else { return }
        let sets = suggestions.map { suggestion in
            NativeWorkoutSet(index: 0, phase: .warmup,
                             weightKg: suggestion.targetWeightKg,
                             reps: suggestion.repsMin ?? firstWork?.reps ?? 8)
        }
        let insertion = exercise.sets.firstIndex(where: { $0.phase == .work }) ?? exercise.sets.count
        draft.exercises[exerciseIndex].sets.insert(contentsOf: sets, at: insertion)
        reindexSets(exerciseIndex)
        touchAndPersist()
    }

    func removeExercise(_ id: UUID) {
        try? NativeWorkoutEngine.removeExercise(id, from: &draft)
        touchAndPersist()
    }

    func moveExercise(_ id: UUID, by offset: Int) {
        guard let from = draft.exercises.firstIndex(where: { $0.id == id }) else { return }
        let destination = from + offset
        guard draft.exercises.indices.contains(destination) else { return }
        try? NativeWorkoutEngine.moveExercise(id, to: destination, in: &draft)
        touchAndPersist()
    }

    /// Replacing an unlogged entry is safe in place. Once a set was recorded, preserve it as the
    /// historical exercise and insert the replacement beside it instead.
    func replaceExercise(_ id: UUID, with replacement: TrainingExercise) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == id }) else { return }
        if draft.exercises[index].sets.contains(where: \.isCompleted) {
            let set = replacement.isUnilateral
                ? NativeWorkoutSet(index: 0, weightKg: replacement.mode == .bodyweightReps ? nil : 0,
                                   leftReps: 8, rightReps: 8)
                : NativeWorkoutSet(index: 0, weightKg: replacement.mode == .bodyweightReps ? nil : 0,
                                   reps: 8)
            var inserted = WorkoutDraft(title: draft.title, startedAt: draft.startedAt,
                                        plannedDay: draft.plannedDay, routineIds: draft.routineIds,
                                        exercises: [], tracker: draft.tracker)
            NativeWorkoutEngine.addExercise(replacement.id, to: &inserted, sets: [set], definition: replacement)
            draft.exercises.insert(inserted.exercises[0], at: index + 1)
        } else {
            draft.exercises[index].exerciseId = replacement.id
            draft.exercises[index].equipmentSnapshot = .init(equipmentIds: replacement.equipmentIds,
                loadSemantics: ExerciseLoadSemantics.defaultValue(for: replacement.mode,
                                                                  equipmentIds: replacement.equipmentIds))
        }
        touchAndPersist()
    }

    func toggleSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].isCompleted.toggle()
        if draft.exercises[exerciseIndex].sets[setIndex].isCompleted {
            draft.cursor = .init(exerciseId: draft.exercises[exerciseIndex].id,
                setId: draft.exercises[exerciseIndex].sets.first(where: { !$0.isCompleted })?.id)
            startRestAfterCompletedSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
        }
        touchAndPersist()
    }

    func skipRest() {
        cancelTimer()
    }

    func adjustTimer(by seconds: Int) {
        guard let timer = draft.timer else { return }
        let now = Int(Date().timeIntervalSince1970)
        draft.timer = WorkoutTimerCoordinator.adjust(timer, by: seconds, now: now)
        scheduleTimerNotification()
        touchAndPersist()
    }

    func pauseTimer() {
        guard let timer = draft.timer else { return }
        draft.timer = WorkoutTimerCoordinator.pause(timer, now: Int(Date().timeIntervalSince1970))
        TrainingRestNotification.cancel(for: draft.id)
        touchAndPersist()
    }

    func resumeTimer() {
        guard let timer = draft.timer else { return }
        draft.timer = WorkoutTimerCoordinator.resume(timer, now: Int(Date().timeIntervalSince1970))
        scheduleTimerNotification()
        touchAndPersist()
    }

    func cancelTimer() {
        draft.timer = nil
        TrainingRestNotification.cancel(for: draft.id)
        touchAndPersist()
    }

    func startTimedSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let set = draft.exercises[exerciseIndex].sets[setIndex]
        let seconds = set.targetDurationS ?? set.durationS ?? 0
        guard let timer = WorkoutTimerCoordinator.start(kind: .timedSet, seconds: seconds,
                                                         exerciseId: draft.exercises[exerciseIndex].id,
                                                         setId: set.id,
                                                         now: Int(Date().timeIntervalSince1970)) else { return }
        draft.timer = timer
        scheduleTimerNotification()
        touchAndPersist()
    }

    func finishTimedSet() {
        guard let timer = draft.timer, timer.kind == .timedSet,
              let exerciseId = timer.exerciseId, let setId = timer.setId,
              let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exerciseId }),
              let setIndex = draft.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else {
            cancelTimer(); return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince1970) - timer.startedAtTs)
        draft.exercises[exerciseIndex].sets[setIndex].durationS = elapsed
        draft.timer = nil
        TrainingRestNotification.cancel(for: draft.id)
        if !draft.exercises[exerciseIndex].sets[setIndex].isCompleted {
            toggleSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
        } else {
            touchAndPersist()
        }
    }

    func adjustWeight(exerciseIndex: Int, setIndex: Int, by delta: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].weightKg ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].weightKg = max(0, old + delta)
        touchAndPersist()
    }

    func adjustReps(exerciseIndex: Int, setIndex: Int, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].reps ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].reps = max(0, old + delta)
        touchAndPersist()
    }

    func adjustSideReps(exerciseIndex: Int, setIndex: Int, left: Bool, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        if left {
            let old = draft.exercises[exerciseIndex].sets[setIndex].leftReps ?? 0
            draft.exercises[exerciseIndex].sets[setIndex].leftReps = max(0, old + delta)
        } else {
            let old = draft.exercises[exerciseIndex].sets[setIndex].rightReps ?? 0
            draft.exercises[exerciseIndex].sets[setIndex].rightReps = max(0, old + delta)
        }
        draft.exercises[exerciseIndex].sets[setIndex].reps = nil
        touchAndPersist()
    }

    func setEffort(exerciseIndex: Int, setIndex: Int, scale: TrainingEffortScale, value: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].effort = .init(scale: scale, value: value)
        touchAndPersist()
    }

    func setWorkoutNote(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.note = trimmed.isEmpty ? nil : value
        touchAndPersist()
    }

    func setWeight(exerciseIndex: Int, setIndex: Int, kg: Double?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].weightKg = kg.map { max(0, $0) }
        touchAndPersist()
    }

    func setReps(exerciseIndex: Int, setIndex: Int, reps: Int?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].reps = reps.map { max(0, $0) }
        touchAndPersist()
    }

    func setSideReps(exerciseIndex: Int, setIndex: Int, left: Bool, reps: Int?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let value = reps.map { max(0, $0) }
        if left { draft.exercises[exerciseIndex].sets[setIndex].leftReps = value }
        else { draft.exercises[exerciseIndex].sets[setIndex].rightReps = value }
        draft.exercises[exerciseIndex].sets[setIndex].reps = nil
        touchAndPersist()
    }

    func setDistance(exerciseIndex: Int, setIndex: Int, meters: Double?) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].distanceM = meters.map { max(0, $0) }
        touchAndPersist()
    }

    func setExerciseNote(_ exerciseId: UUID, _ value: String) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        draft.exercises[index].note = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        touchAndPersist()
    }

    /// Ends the exercise early and moves on to the next exercise that still has open sets.
    func skipExercise(_ exerciseId: UUID) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        let nextId = draft.exercises.indices
            .first { $0 > index && draft.exercises[$0].sets.contains(where: { !$0.isCompleted }) }
            .map { draft.exercises[$0].id }
        try? NativeWorkoutEngine.skipRemainingSets(of: exerciseId, in: &draft)
        if let timer = draft.timer, timer.kind == .timedSet, timer.exerciseId == exerciseId {
            draft.timer = nil
            TrainingRestNotification.cancel(for: draft.id)
        }
        if let nextId, let next = draft.exercises.firstIndex(where: { $0.id == nextId }) {
            selectExercise(at: next)
        } else {
            touchAndPersist()
        }
    }

    func adjustDuration(exerciseIndex: Int, setIndex: Int, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].durationS ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].durationS = max(0, old + delta)
        touchAndPersist()
    }

    func adjustDistance(exerciseIndex: Int, setIndex: Int, by delta: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].distanceM ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].distanceM = max(0, old + delta)
        touchAndPersist()
    }

    func setKind(exerciseIndex: Int, setIndex: Int, phase: TrainingSetPhase,
                 intensifier: TrainingSetIntensifier) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].phase = phase
        draft.exercises[exerciseIndex].sets[setIndex].intensifier = intensifier
        touchAndPersist()
    }

    func addTechniqueSegment(exerciseIndex: Int, setIndex: Int, intensifier: TrainingSetIntensifier) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let origin = draft.exercises[exerciseIndex].sets[setIndex]
        try? NativeWorkoutEngine.appendSegment(to: origin.id, intensifier: intensifier, in: &draft)
        touchAndPersist()
    }

    func removeSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets.remove(at: setIndex)
        reindexSets(exerciseIndex)
        touchAndPersist()
    }

    func duplicateSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let source = draft.exercises[exerciseIndex].sets[setIndex]
        let duplicate = NativeWorkoutSet(index: 0, phase: source.phase,
                                         intensifier: source.isClusterSegment ? .none : source.intensifier,
                                         weightKg: source.weightKg, reps: source.reps,
                                         leftReps: source.leftReps, rightReps: source.rightReps,
                                         targetDurationS: source.targetDurationS,
                                         durationS: source.durationS, distanceM: source.distanceM,
                                         effort: source.effort)
        draft.exercises[exerciseIndex].sets.insert(duplicate, at: setIndex + 1)
        reindexSets(exerciseIndex)
        touchAndPersist()
    }

    func supersetWithNext(exerciseIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises.indices.contains(exerciseIndex + 1) else { return }
        try? NativeWorkoutEngine.formSuperset(
            [draft.exercises[exerciseIndex].id, draft.exercises[exerciseIndex + 1].id], in: &draft)
        touchAndPersist()
    }

    func dissolveSuperset(_ group: UUID) {
        NativeWorkoutEngine.dissolveSuperset(group, in: &draft)
        touchAndPersist()
    }

    func finish() async -> NativeWorkout? {
        var physiologyEnded = false
        do {
            let end = draft.plannedEndTs ?? Int(Date().timeIntervalSince1970)
            var workout = try NativeWorkoutEngine.complete(
                draft: draft, endTs: end,
                sessionRPE: sessionRPE)
            draft.state = .completing
            let physiology = coordinator.complete(draft, endedAt: end)
            physiologyEnded = true
            workout.trainingSessionId = draft.trainingSessionId
            workout.physiologyProvider = physiology.provider
            workout.physiologyComponentKey = physiology.componentKey
            workout.hrCoverage = physiology.hrCoverage
            workout.lifecycleVersion = draft.lifecycleVersion
            try await repo.finishNativeWorkout(workout)
            await repo.linkNativeWorkoutPhysiology(workout)
            TrainingRestNotification.cancel(for: draft.id)
            return workout
        } catch WorkoutMutationError.noCompletedWork {
            errorMessage = String(localized: "Complete at least one set before finishing.")
        } catch {
            if physiologyEnded {
                draft.state = .interrupted
                draft.interruptionReason = .systemInterruption
                touchAndPersist()
            }
            errorMessage = String(localized: "The workout could not be saved.")
        }
        return nil
    }

    /// Throws the session away without recording it.
    ///
    /// The draft is deleted only after the writes already in flight have landed, so a save queued a
    /// moment earlier cannot put the discarded draft back. Everything the session held open goes with
    /// it: the rest timer's notification, the Watch companion, and the physiological recording this
    /// session started. Returns false when the delete failed, so the caller keeps the logger open
    /// rather than reporting a discard that did not happen.
    func discard() async -> Bool {
        discarded = true
        await pendingPersist?.value
        do {
            try await repo.discardNativeWorkoutDraft(draft)
        } catch {
            discarded = false
            errorMessage = String(localized: "The workout could not be discarded.")
            return false
        }
        coordinator.abandon(draft)
        TrainingRestNotification.cancel(for: draft.id)
        return true
    }

    private func startRestAfterCompletedSet(exerciseIndex: Int, setIndex: Int) {
        let exercise = draft.exercises[exerciseIndex]
        let set = exercise.sets[setIndex]
        guard shouldRest(after: set, exerciseIndex: exerciseIndex) else { return }
        let seconds: Int
        if set.intensifier == .restPause { seconds = TrainingPreferences.restPauseSeconds }
        else { seconds = NativeWorkoutEngine.restSeconds(after: set, in: exercise) }
        guard let timer = WorkoutTimerCoordinator.start(kind: set.intensifier == .restPause ? .restPause : .rest,
                                                         seconds: seconds, exerciseId: exercise.id,
                                                         setId: set.id, now: Int(Date().timeIntervalSince1970)) else { return }
        draft.timer = timer
        scheduleTimerNotification()
    }

    private func shouldRest(after set: NativeWorkoutSet, exerciseIndex: Int) -> Bool {
        guard let group = draft.exercises[exerciseIndex].supersetId else { return true }
        let ordinal = draft.exercises[exerciseIndex].sets.filter { $0.phase == .work && $0.index <= set.index }.count
        let groupExercises = draft.exercises.filter { $0.supersetId == group }
        return groupExercises.allSatisfy { exercise in
            exercise.sets.filter { $0.phase == .work }.prefix(ordinal).allSatisfy(\.isCompleted)
        }
    }

    private func scheduleTimerNotification() {
        guard let timer = draft.timer, timer.pausedRemainingSeconds == nil else { return }
        guard TrainingPreferences.timerFeedbackEnabled else { return }
        TrainingRestNotification.schedule(identifier: draft.id,
            at: Date(timeIntervalSince1970: TimeInterval(timer.endsAtTs)),
            kind: timer.kind, sound: TrainingPreferences.timerSoundEnabled)
    }

    private func reindexSets(_ exerciseIndex: Int) {
        for index in draft.exercises[exerciseIndex].sets.indices {
            draft.exercises[exerciseIndex].sets[index].index = index
        }
    }

    private func touchAndPersist() {
        draft.updatedAt = max(draft.updatedAt + 1, Int(Date().timeIntervalSince1970))
        publishCompanionState()
        persist()
    }

    private func publishCompanionState() {
        guard draft.exercises.indices.contains(activeExerciseIndex) else {
            coordinator.publish(draft, exerciseTitle: nil, setNumber: nil); return
        }
        let exercise = draft.exercises[activeExerciseIndex]
        let setNumber = exercise.sets.firstIndex(where: { !$0.isCompleted }).map { $0 + 1 }
        coordinator.publish(draft, exerciseTitle: exerciseTitles[exercise.exerciseId], setNumber: setNumber)
    }

    private func handleWatchCommand(_ command: StrengthWorkoutCompanionCommand) {
        guard command.sessionId == draft.trainingSessionId,
              command.expectedRevision == draft.updatedAt else { return }
        draft.lastConfirmedWatchRevision = max(draft.lastConfirmedWatchRevision ?? 0,
                                               command.expectedRevision)
        switch command.kind {
        case .pause where draft.state == .active: toggleWorkoutPause()
        case .resume where draft.state != .active: toggleWorkoutPause()
        case .completeSet:
            guard draft.exercises.indices.contains(activeExerciseIndex),
                  let setIndex = draft.exercises[activeExerciseIndex].sets.firstIndex(where: { !$0.isCompleted }) else { return }
            toggleSet(exerciseIndex: activeExerciseIndex, setIndex: setIndex)
        case .finish: watchFinishRequested = true
        default: break
        }
    }

    /// Saves the draft in the order the edits were made, and stops once the session has been discarded.
    /// Chaining each write onto the previous one is what lets `discard` know when the last save landed.
    private func persist() {
        guard !discarded else { return }
        let snapshot = draft
        let previous = pendingPersist
        pendingPersist = Task {
            await previous?.value
            do { try await repo.saveNativeWorkoutDraft(snapshot) }
            catch { errorMessage = String(localized: "Changes could not be saved.") }
        }
    }
}

private enum TrainingRestNotification {
    private static func id(_ workoutId: UUID) -> String { "training-rest-\(workoutId.uuidString)" }

    static func schedule(identifier workoutId: UUID, at date: Date,
                         kind: WorkoutTimerKind, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            let allowed: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: allowed = true
            case .notDetermined: allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            default: allowed = false
            }
            guard allowed else { return }
            center.removePendingNotificationRequests(withIdentifiers: [id(workoutId)])
            let content = UNMutableNotificationContent()
            content.title = String(localized: kind == .timedSet ? "Set complete" : "Rest complete")
            content.body = String(localized: kind == .timedSet ? "Your timed set is ready to finish." : "Your next set is ready.")
            if sound { content.sound = .default }
            let seconds = max(1, date.timeIntervalSinceNow)
            try? await center.add(UNNotificationRequest(identifier: id(workoutId), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
        }
    }

    static func cancel(for workoutId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id(workoutId)])
    }
}
