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
    /// Days of the past year with minutes logged, computed once per load rather than in a view body.
    @Published private(set) var activityDays: [TrainingActivityDay] = []
    @Published var historyImportPreview: HistoryImportPreview?
    @Published var errorMessage: String?

    /// Reads the plan and the whole resolved history. While a live session runs this is skipped once
    /// something is loaded: nothing the hub shows changes mid-workout, and resolving every session again
    /// on each data refresh is exactly the work that made logging stutter.
    func load(repo: Repository, session: ActiveSessionController? = nil,
              weekStartsOn: TrainingWeekStart = .monday, force: Bool = false) async {
        if !force, loaded, session?.hasLiveSession == true { return }
        await repo.prepareNativeTraining()
        async let exercises = repo.nativeTrainingExercises()
        async let plan = repo.nativeTrainingPlan(weekStartsOn: weekStartsOn)
        async let workouts = repo.nativeWorkouts()
        async let trackers = repo.nativeTrainingTrackers()
        async let resolved = repo.resolvedStrengthHistory(days: ResolvedStrengthHistory.allHistoryDays)
        self.exercises = await exercises
        self.plan = await plan
        self.workouts = await workouts
        self.trackers = await trackers
        self.resolvedHistory = await resolved
        refreshPerformanceHistory()
        activityDays = TrainingActivityDay.pastYear(sessions: resolvedHistory.sessions,
                                                    weekStart: weekStartsOn)
        loaded = true
        session?.update(context: startContext)
    }

    var startContext: TrainingStartContext {
        TrainingStartContext(exercises: exercises, plan: plan, workouts: workouts,
                             performance: performanceHistory)
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
}
