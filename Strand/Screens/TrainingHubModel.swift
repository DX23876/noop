import Foundation
import StrandTraining
import UserNotifications

@MainActor
final class TrainingHubModel: ObservableObject {
    @Published private(set) var loaded = false
    @Published private(set) var exercises: [TrainingExercise] = []
    @Published private(set) var plan = TrainingPlan()
    @Published private(set) var workouts: [NativeWorkout] = []
    @Published private(set) var trackers: [SessionTrackerAttribution] = []
    @Published var draft: WorkoutDraft?
    @Published var errorMessage: String?

    func load(repo: Repository) async {
        await repo.prepareNativeTraining()
        async let exercises = repo.nativeTrainingExercises()
        async let plan = repo.nativeTrainingPlan()
        async let workouts = repo.nativeWorkouts()
        async let trackers = repo.nativeTrainingTrackers()
        async let draft = repo.nativeWorkoutDraft()
        self.exercises = await exercises
        self.plan = await plan
        self.workouts = await workouts
        self.trackers = await trackers
        self.draft = await draft
        loaded = true
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
                                               routines: routines, tracker: tracker)
        var prepared = value
        normalizeUnilateralSets(in: &prepared)
        if let pastDurationS { prepared.plannedEndTs = now + max(60, pastDurationS) }
        NativeWorkoutEngine.prefillLastPerformance(&prepared, history: workouts)
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
        } catch {
            errorMessage = String(localized: "The exercise could not be saved.")
        }
    }

    func saveRoutine(_ routine: TrainingRoutine, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingRoutine(routine)
            plan = await repo.nativeTrainingPlan()
        } catch {
            errorMessage = String(localized: "The routine could not be saved.")
        }
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
            await load(repo: repo)
        } catch {
            errorMessage = String(localized: "The training plan could not be imported.")
        }
    }

    func importHistory(_ data: Data, repo: Repository) async {
        do {
            let result = try TrainingCSVImporter.parse(data, existingExercises: exercises)
            try await repo.importNativeTrainingHistory(result)
            await load(repo: repo)
            errorMessage = result.skippedRows > 0
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
        draft = nil
        await load(repo: repo)
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
            let history = workouts.sorted { $0.startedAt < $1.startedAt }.compactMap { workout -> ProgressionSession? in
                guard let prior = workout.exercises.first(where: { $0.exerciseId == planned.exerciseId }) else { return nil }
                let work = prior.sets.filter { $0.phase == .work && $0.isCompleted }
                guard !work.isEmpty else { return nil }
                return ProgressionSession(
                    weightKg: work.compactMap(\.weightKg).max(),
                    completedReps: work.compactMap(Self.completedReps),
                    targetReps: Array(repeating: configuration.repsMin,
                                      count: work.compactMap(Self.completedReps).count),
                    durationS: work.compactMap(\.durationS).max(),
                    targetDurationS: planned.sets.compactMap(\.targetDurationS).max(),
                    workSetCount: work.count)
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
    @Published var sessionRPE = 7.0
    @Published var restEndsAt: Date?
    @Published var errorMessage: String?

    private let repo: Repository

    init(draft: WorkoutDraft, repo: Repository) {
        self.draft = draft
        self.repo = repo
    }

    func addExercise(_ exercise: TrainingExercise) {
        let initial = exercise.isUnilateral
            ? NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0,
                               leftReps: 8, rightReps: 8)
            : NativeWorkoutSet(index: 0, weightKg: exercise.mode == .bodyweightReps ? nil : 0,
                               reps: 8)
        NativeWorkoutEngine.addExercise(exercise.id, to: &draft,
            sets: [initial])
        persist()
    }

    func addSet(to exerciseId: UUID) {
        try? NativeWorkoutEngine.appendSet(to: exerciseId, in: &draft)
        persist()
    }

    func removeExercise(_ id: UUID) {
        try? NativeWorkoutEngine.removeExercise(id, from: &draft)
        persist()
    }

    func toggleSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].isCompleted.toggle()
        if draft.exercises[exerciseIndex].sets[setIndex].isCompleted {
            restEndsAt = Date().addingTimeInterval(TimeInterval(draft.exercises[exerciseIndex].restSeconds))
            if let restEndsAt, draft.exercises[exerciseIndex].restSeconds > 0 {
                TrainingRestNotification.schedule(at: restEndsAt)
            }
        }
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func skipRest() {
        restEndsAt = nil
        TrainingRestNotification.cancel()
    }

    func adjustWeight(exerciseIndex: Int, setIndex: Int, by delta: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].weightKg ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].weightKg = max(0, old + delta)
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func adjustReps(exerciseIndex: Int, setIndex: Int, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].reps ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].reps = max(0, old + delta)
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
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
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func setEffort(exerciseIndex: Int, setIndex: Int, scale: TrainingEffortScale, value: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].effort = .init(scale: scale, value: value)
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func setWorkoutNote(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.note = trimmed.isEmpty ? nil : value
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func adjustDuration(exerciseIndex: Int, setIndex: Int, by delta: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].durationS ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].durationS = max(0, old + delta)
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func adjustDistance(exerciseIndex: Int, setIndex: Int, by delta: Double) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        let old = draft.exercises[exerciseIndex].sets[setIndex].distanceM ?? 0
        draft.exercises[exerciseIndex].sets[setIndex].distanceM = max(0, old + delta)
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func setKind(exerciseIndex: Int, setIndex: Int, phase: TrainingSetPhase,
                 intensifier: TrainingSetIntensifier) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets[setIndex].phase = phase
        draft.exercises[exerciseIndex].sets[setIndex].intensifier = intensifier
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func removeSet(exerciseIndex: Int, setIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return }
        draft.exercises[exerciseIndex].sets.remove(at: setIndex)
        for index in draft.exercises[exerciseIndex].sets.indices {
            draft.exercises[exerciseIndex].sets[index].index = index
        }
        draft.updatedAt = Int(Date().timeIntervalSince1970)
        persist()
    }

    func supersetWithNext(exerciseIndex: Int) {
        guard draft.exercises.indices.contains(exerciseIndex),
              draft.exercises.indices.contains(exerciseIndex + 1) else { return }
        try? NativeWorkoutEngine.formSuperset(
            [draft.exercises[exerciseIndex].id, draft.exercises[exerciseIndex + 1].id], in: &draft)
        persist()
    }

    func finish() async -> Bool {
        do {
            let workout = try NativeWorkoutEngine.complete(
                draft: draft, endTs: draft.plannedEndTs ?? Int(Date().timeIntervalSince1970),
                sessionRPE: sessionRPE)
            try await repo.finishNativeWorkout(workout)
            TrainingRestNotification.cancel()
            return true
        } catch WorkoutMutationError.noCompletedWork {
            errorMessage = String(localized: "Complete at least one set before finishing.")
        } catch {
            errorMessage = String(localized: "The workout could not be saved.")
        }
        return false
    }

    private func persist() {
        let snapshot = draft
        Task {
            do { try await repo.saveNativeWorkoutDraft(snapshot) }
            catch { errorMessage = String(localized: "Changes could not be saved.") }
        }
    }
}

private enum TrainingRestNotification {
    private static let id = "training-rest-complete"

    static func schedule(at date: Date) {
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
            center.removePendingNotificationRequests(withIdentifiers: [id])
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Rest complete")
            content.body = String(localized: "Your next set is ready.")
            content.sound = .default
            let seconds = max(1, date.timeIntervalSinceNow)
            try? await center.add(UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
